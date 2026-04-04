# Deploy Skill
1. Run `git status` to verify changes
2. Run `flux check` to verify Flux is healthy
3. Commit changes with conventional commit message
4. Push to origin
5. Run `flux reconcile kustomization flux-system --with-source`
6. Watch for reconciliation: `flux get kustomizations -w`
