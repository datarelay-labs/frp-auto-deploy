# GitHub upload

This project is published at https://github.com/RickLee-kr/frp-auto-deploy.

Do not commit runtime secrets (`server_token`, enrollment files, `frpc.toml`, `registry.json`, or `access-info.txt`).

From the project directory:

```bash
git init
git branch -M main
git add .
git commit -m "feat: initial self-hosted FRP auto deployment"
git remote add origin https://github.com/RickLee-kr/frp-auto-deploy.git
git push -u origin main
```

Then configure the installed FRP server so `frp-create-client` prints the correct client installer command:

```bash
sudo frp-set-client-installer-url \
  https://raw.githubusercontent.com/RickLee-kr/frp-auto-deploy/main/dist/bootstrap-client.sh
```

Server one-liner after the repository is pushed:

```bash
curl -fsSL https://raw.githubusercontent.com/RickLee-kr/frp-auto-deploy/main/dist/bootstrap-server.sh | sudo bash
```

Client one-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/RickLee-kr/frp-auto-deploy/main/dist/bootstrap-client.sh | sudo bash
```
