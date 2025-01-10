### Export needed env-vars for terraform
export TF_VAR_humanitec_org=$HUMANITEC_ORG
# Aim for service user if present, otherwise use current user token (max 24h validity)
if [ -n "$HUMANITEC_SERVICE_USER" ]; then
  export TF_VAR_humanitec_token=$HUMANITEC_SERVICE_USER
else
  export TF_VAR_humanitec_token=$(yq -r '.token' ~/.humctl)
fi
# Variables for TLS in Terraform
export TF_VAR_tls_ca_cert=$TLS_CA_CERT
export TF_VAR_tls_cert_string=$TLS_CERT_STRING
export TF_VAR_tls_key_string=$TLS_KEY_STRING

terraform -chdir=setup/terraform destroy -auto-approve