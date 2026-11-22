package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/dynamicpb"
	"google.golang.org/protobuf/types/known/emptypb"
)

type agentIdentity struct {
	namespace, name, uid string
}

type resolveIdentity func(context.Context, string) (agentIdentity, error)

func authorizer(allowed map[string]bool, resolve resolveIdentity) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/check", func(w http.ResponseWriter, r *http.Request) {
		values := r.Header.Values("Authorization")
		if len(values) != 1 || !strings.HasPrefix(values[0], "Bearer ") {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		token := strings.TrimPrefix(values[0], "Bearer ")
		if token == "" || strings.ContainsAny(token, " ,\t") {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), time.Second)
		defer cancel()
		agent, err := resolve(ctx, token)
		if err != nil {
			log.Print("decision=deny reason=identity_resolution_failed")
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		key := agent.namespace + "/" + agent.name
		if agent.uid == "" || !allowed[key] {
			log.Printf("decision=deny agent=%q reason=outside_allowlist", key)
			w.WriteHeader(http.StatusForbidden)
			return
		}
		log.Printf("decision=allow agent=%q", key)
		w.WriteHeader(http.StatusNoContent)
	})
	return mux
}

// Decode only the fields used by the policy from kagent v1.0.1's agent_identity.proto.
func newResolver(conn grpc.ClientConnInterface) (resolveIdentity, error) {
	stringField := func(name string, number int32) *descriptorpb.FieldDescriptorProto {
		return &descriptorpb.FieldDescriptorProto{
			Name: proto.String(name), Number: proto.Int32(number), Type: descriptorpb.FieldDescriptorProto_TYPE_STRING.Enum(),
		}
	}
	desc, err := protodesc.NewFile(&descriptorpb.FileDescriptorProto{
		Name: proto.String("agent_identity.proto"), Package: proto.String("kagent.api.v1"), Syntax: proto.String("proto3"),
		MessageType: []*descriptorpb.DescriptorProto{
			{Name: proto.String("AgentIdentity"), Field: []*descriptorpb.FieldDescriptorProto{
				stringField("namespace", 1), stringField("name", 2), stringField("uid", 3),
			}},
			{Name: proto.String("ResolveAgentIdentityResponse"), Field: []*descriptorpb.FieldDescriptorProto{
				{Name: proto.String("agent"), Number: proto.Int32(1), Type: descriptorpb.FieldDescriptorProto_TYPE_MESSAGE.Enum(), TypeName: proto.String(".kagent.api.v1.AgentIdentity")},
			}},
		},
	}, nil)
	if err != nil {
		return nil, err
	}
	responseType := desc.Messages().ByName("ResolveAgentIdentityResponse")
	field := responseType.Fields().ByName("agent")
	fields := field.Message().Fields()
	return func(ctx context.Context, token string) (agentIdentity, error) {
		ctx = metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+token)
		response := dynamicpb.NewMessage(responseType)
		const method = "/kagent.api.v1.AgentIdentityService/ResolveAgentIdentity"
		if err := conn.Invoke(ctx, method, &emptypb.Empty{}, response); err != nil {
			return agentIdentity{}, err
		}
		if !response.Has(field) {
			return agentIdentity{}, errors.New("missing agent identity")
		}
		agent := response.Get(field).Message()
		return agentIdentity{
			namespace: agent.Get(fields.ByName("namespace")).String(),
			name:      agent.Get(fields.ByName("name")).String(),
			uid:       agent.Get(fields.ByName("uid")).String(),
		}, nil
	}, nil
}

func main() {
	target := os.Getenv("KAGENT_CONTROLLER")
	if target == "" {
		log.Fatal("KAGENT_CONTROLLER is required")
	}
	allowed := make(map[string]bool)
	for _, entry := range strings.Fields(os.Getenv("ALLOWED_AGENTS")) {
		namespace, name, ok := strings.Cut(entry, "/")
		if !ok || namespace == "" || name == "" || strings.Contains(name, "/") {
			log.Fatal("ALLOWED_AGENTS must contain namespace/name pairs")
		}
		allowed[entry] = true
	}
	if len(allowed) == 0 {
		log.Fatal("ALLOWED_AGENTS is empty")
	}

	// The controller in this lab exposes h2c on its internal service.
	conn, err := grpc.NewClient(target, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatal(err)
	}
	defer conn.Close()
	resolve, err := newResolver(conn)
	if err != nil {
		log.Fatal(err)
	}
	server := &http.Server{
		Addr: "127.0.0.1:8090", Handler: authorizer(allowed, resolve),
		ReadHeaderTimeout: 3 * time.Second, WriteTimeout: 3 * time.Second,
		IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 << 10,
	}
	log.Fatal(server.ListenAndServe())
}
