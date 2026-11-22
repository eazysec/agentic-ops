FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /authorizer .

FROM scratch
COPY --from=build /authorizer /authorizer
USER 10001
ENTRYPOINT ["/authorizer"]
