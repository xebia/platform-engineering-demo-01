
AKS platform-engineering reference architecture. Just 
supports)

1. GitOps delivery (the core loop)
Dev pushes to git → ArgoCD syncs → app deployed. No kubectl apply by hand. This is the headline scenario and the one you're 1 step away from.


4. Onboarding a new workload/team
Add a folder under workloads/, add one ArgoCD Application (App-of-Apps pattern). Shows how a platform scales to many teams from one repo.
source limits, required labels, no :latest). Reference arch calls this "limits enforced by policies from the Platform Engineering team."

7. Progressive delivery
Argo Rollouts for canary/blue-green of the hello-world app.

Demonstrable locally on kind (what your current stack supports)

1. GitOps delivery (the core loop)
Dev pushes to git → ArgoCD syncs → app deployed. No kubectl apply by hand. This is the headline scenario and the one you're 1 step away from.

2. Developer self-service via Score (the "golden path")
The developer's only interface is score.yaml. They never touch Deployments, Services, Ingress. score-k8s/score-compose generate the rest. Demos the IDP abstraction — "describe intent, not infrastructure."

3. Local/cloud portability
Same score.yaml → compose.yaml for laptop dev, manifests.yaml for the cluster. Shows write-once-run-anywhere.

4. Onboarding a new workload/team
Add a folder under workloads/, add one ArgoCD Application (App-of-Apps pattern). Shows how a platform scales to many teams from one repo.

5. Day-2 platform addons via GitOps
Platform team installs ingress-nginx, c as ArgoCD apps in a gitops/addons/
folder — separate from app code. Mirrorol plane bootstrapped with Day-2 tools."

6. Policy guardrails
Kyverno or OPA/Gatekeeper enforcing pla required labels, no :latest). Referencearch calls this "limits enforced by policies from the Platform Engineering team."

7. Progressive delivery
Argo Rollouts for canary/blue-green of the hello-world app.

Requires the full Azure/AKS version (Cr

8. Cluster-as-a-service / multi-cluster
Platform team provisions a new AKS cluster per team via Crossplane or CAPZ, auto-bootstrapped with ArgoCD +
addons. This is the reference architect— and the part kind can only simulate(e.g. a second kind cluster instead of real AKS).

9. Infrastructure-as-a-service through
Dev requests a database/storage accountl Azure resources provisioned. Score has
resource provisioners that map to this.

10. Environment promotion (dev → stagin
Across clusters/namespaces, driven by Gategy.Azure/AKS version.

Demonstrable locally on kind (what your current stack supports)

1. GitOps delivery (the core loop)
Dev pushes to git → ArgoCD syncs → app  hand. This is the headline scenario and
the one you're 1 step away from.

2. Developer self-service via Score (the "golden path")
The developer's only interface is score.yaml. They never touch Deployments, Services, Ingress.
score-k8s/score-compose generate the re — "describe intent, not infrastructure."

3. Local/cloud portability
Same score.yaml → compose.yaml for lapte cluster. Shows write-once-run-anywhere.

4. Onboarding a new workload/team
Add a folder under workloads/, add one ArgoCD Application (App-of-Apps pattern). Shows how a platform scales to many teams from one repo.

5. Day-2 platform addons via GitOps                                                                       Platform team installs ingress-nginx, c as ArgoCD apps in a gitops/addons/folder — separate from app code. Mirrors the reference arch's "control plane bootstrapped with Day-2 tools."

6. Policy guardrails                                                                                      Kyverno or OPA/Gatekeeper enforcing pla required labels, no :latest). Referencearch calls this "limits enforced by policies from the Platform Engineering team."
                                                                                                          7. Progressive delivery
Argo Rollouts for canary/blue-green of the hello-world app.

Requires the full Azure/AKS version (Crossplane or CAPZ)

8. Cluster-as-a-service / multi-cluster provisioning
Platform team provisions a new AKS cluster per team via Crossplane or CAPZ, auto-bootstrapped with ArgoCD + addons. This is the reference architecture's biggest differentiator — and the part kind can only simulate (e.g. a second kind cluster instead of

9. Infrastructure-as-a-service through the platform
Dev requests a database/storage account via a Crossplane Claim → real Azure resources provisioned. Score has resource provisioners that map to this.

10. Environment promotion (dev → staging → prod)
Across clusters/namespaces, driven by GitOps directory or branch strategy.
