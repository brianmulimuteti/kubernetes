# First generate a private Key
openssl genrsa -out myuser.key 3072

# Create an X.509 certificate signing request. Change CN
openssl req -new -key myuser.key -out myuser.csr -subj "/CN=myuser"

# create a CSR.yml file for this CSR
the pasted CSR is to be in one line Base 64 so it can be added in "request" part - command
cat file.csr | base64 | tr -d "\n"

# apply the csr.yaml
kubectl apply -f csr.yaml
kubectl get csr
kubectl certificate approve <csr-name>

# Share approved csr with user
kubectl get csr <csr-name> -o yaml > issuedcsr.yaml

echo <certificate> | base64 -d
