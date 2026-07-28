1. Create a GitHub PAT (web UI, one-time) — classic token with write:packages scope.

2. Log in:
echo "$GHCR_TOKEN" | podman login ghcr.io -u <your-github-username> --password-stdin

3. Tag the image:
podman tag localhost/tp-reconc-demo:latest ghcr.io/mpilhlt/tei-publisher-reconcile/tp-reconc-demo:latest
podman tag localhost/tp-reconc-demo:latest ghcr.io/mpilhlt/tei-publisher-reconcile/tp-reconc-demo:<version>

4. Push:
podman push ghcr.io/mpilhlt/tei-publisher-reconcile/tp-reconc-demo:latest
podman push ghcr.io/mpilhlt/tei-publisher-reconcile/tp-reconc-demo:<version>

5. Make it public (web UI, one-time) — GHCR packages default to private; go to the package's page → Settings → Change visibility → Public. Optionally "Connect Repository" too.

6. Optional sanity check from clean state:
podman pull ghcr.io/mpilhlt/tei-publisher-reconcile/tp-reconc-demo:latest
podman run -d --name tp-reconc-demo-ghcr -p 8080:8080 ghcr.io/mpilhlt/tei-publisher-reconcile/tp-reconc-demo:latest
