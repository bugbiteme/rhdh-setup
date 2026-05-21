oc delete secret my-rhdh-secrets -n rhdh
oc -n rhdh create secret generic my-rhdh-secrets --from-env-file=manifests/rhdh/secrets.txt
oc delete configmap my-rhdh-app-config -n rhdh
oc -n rhdh create configmap my-rhdh-app-config --from-file=manifests/rhdh/app-config.yaml
oc -n rhdh delete configmap dynamic-plugins-rhdh
oc -n rhdh create configmap dynamic-plugins-rhdh --from-file=manifests/rhdh/dynamic-plugins.yaml
oc rollout restart deployment backstage-rhdh-instance -n rhdh
