# Mini-projet factice pour iaas-ops et iac-review. Défauts VOLONTAIRES, à trouver par l'agent :
# 1. mot de passe en clair en valeur par défaut  2. variable sans description ni type  3. mise en forme non standard
variable "db_password" {
  default = "MotDePasse123!"
}
variable "env" {
default="banc"
}
resource "terraform_data" "serveur" {
  input = {
    nom      = "web-${var.env}"
    password = var.db_password
  }
}
output "connexion" {
  value = terraform_data.serveur.output
}
