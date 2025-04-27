#!/bin/bash

set -e -x
arguments=$@
username=harp00n
log_path=/var/log/${username}
usr_path=/usr/share/${username}
trigger_branch="production"

function display_info {
    echo "
Welcome to Harp00n,

Configure this machine for push-to-deploy.

Author: massimo.dipierro@gmail.com
License: https://opensource.org/license/bsd-3-clause

Harp00n will setup this machine as follows:

- download some useful packages (git, curl, podman, podman-compose, caddy, uv)
- setup the firewall to only allow ssh, http, https
- create an harp00n account
- setup its hostname
- setup a Caddy service
- setup an SSL certificate using Let's Encrypt for Caddy
- setup an harp00n service which listens to /_harp00n/gitpost as harp00n
- setup a webhook for the specified repository

When you commit anything to the repo (branch ${trigger_branch}):

- github will POST to https://{yourdomain}/_harp00n/gitpost
- harp00n will pull the branch in ${usr_path}/checkout
- harp00n will execute the init.sh from the root of your repo
- harp00n service logs will be in ${log_path}/8111/current
- the user installed service logs will be in ${log_path}/8000/current
"
}

function display_post_info {
    echo "
To deply simply commit to

    https://github.com/{repository} (branch ${trigger_branch})

Checks logs on

    https://github.com/${repository}/settings/hooks/

That's all folks!
"
}

function read_input {
    # variable name, comment, default
    local value=""
    local check="--$1="
    for arg in $arguments; do
	if [ "${arg:0:${#check}}" == "$check" ];
	then
	    value="${arg#$check}"
	    break
	fi
    done
    if [ -z "$value" ]; then
	read -p "Enter value for $1 ($2): " value
    fi
    eval "$1=\"$value\""
    echo "Using $1=$value"
}


function install_dependencies {
    echo "==== Installing packages ===="
    apt update
    apt install -y bash curl sudo ufw git tmux htop zip unzip daemontools
    apt install -y podman podman-compose caddy
    apt install -y emacs-nox --no-install-recommends
}


function install_uv {
    echo "==== Installing uv ===="
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh
}


function create_accounts {
    if ! id "$username" &>/dev/null; then
	echo "==== Creating account $username ===="
	useradd -m -s /bin/bash "$username"
    fi
    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $username
    loginctl enable-linger 1000
    echo "$username ALL=(ALL) NOPASSWD: /usr/bin/systemctl start harp00n-8000.service" >/etc/sudoers.d/$username
    echo "$username ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop harp00n-8000.service" >>/etc/sudoers.d/$username
    echo "$username ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart harp00n-8000.service" >>/etc/sudoers.d/$username
    echo "$username ALL=(ALL) NOPASSWD: /usr/bin/systemctl status harp00n-8000.service" >>/etc/sudoers.d/$username
}


function setup_firewall {
    echo "==== Setup firewall ===="
    ufw allow ssh
    ufw allow http
    ufw allow https
    ufw allow out 80
    ufw allow out 443
    ufw allow in on lo
    ufw allow out on lo
    ufw --force enable
}


function setup_domain_name {
    if [ "$domain" != "" ];
    then
	echo "==== Setting hostname ===="
	sudo hostnamectl set-hostname ${domain}
    fi
}


function setup_caddy_service {
    echo "==== Generating a Caddy config file ===="
    cat > /etc/caddy/Caddyfile <<EOF
${domain} {
   handle /_harp00n/* {
     reverse_proxy 127.0.0.1:8111
   }
   handle {
     reverse_proxy 127.0.0.1:8000
   }
   handle_errors {
     respond "Welcome to HARP00N. Upstream proxy (port 8000) not configured." 502
   }
}
EOF
    caddy reload --config=/etc/caddy/Caddyfile
}


function setup_harp00n_services {
    echo "==== Generating a script that will run in background ===="
    service harp00n stop || true
    mkdir -p ${log_path}/ && chown harp00n ${log_path}/
    mkdir -p ${usr_path}/ && chown harp00n ${usr_path}/
    script_path=${usr_path}/harp00n.py
    cat > $script_path <<EOF
import contextlib
import datetime
import hashlib
import hmac
import os
import re
import shutil
import subprocess
import threading
import ombott

LOCK = threading.Lock()
USR_PATH = "${usr_path}"
GITHUB_TOKEN = "${github_token}"
WEBHOOK_SECRET = "${webhook_secret}"

@contextlib.contextmanager
def acquire_timeout(lock, timeout):
    result = lock.acquire(timeout=timeout)
    try:
        yield result
    finally:
        if result:
            lock.release()

class Runner:
    def __init__(self):
        self.output = ""
    def run(self, cmd, cwd=".", shell=True, check=True, timeout=600):
        now = str(datetime.datetime.now(datetime.UTC))[:23]
        self.output += f"[{now}] {cmd} in {cwd}\n"
        res = subprocess.run(cmd, shell=shell, check=False, cwd=cwd, timeout=timeout, capture_output=True, text=True)
        self.output += res.stdout + "\n" if res.stdout else ""
        self.output += res.stderr + "\n" if res.stderr else ""
        if res.returncode != 0:
            self.output += f"recurncode: {res.returncode}" + "\n"
            if check:
                raise RuntimeError

def upgrade(url, branch, commit, cwd):
    url = url.replace(":", "/").replace("git@", "https://")
    url = url.replace("://", f"://x-access-token:{GITHUB_TOKEN}@")
    name = url.split("/")[-1][:-4]
    path = os.path.join(cwd, "checkout")
    runner = Runner()
    if (not re.compile(r'[\w:/-@]+').match(url) or
        not re.compile(r'[\w-]+').match(branch) or
        not re.compile(r'[1-9a-f]+').match(commit)):
        return False, "invalid request"
    try:
        try:
            runner.run(f"git config --global --add safe.directory {path}")
            runner.run(f"git rev-parse", cwd=path)
        except Exception:
            if os.path.exists(path):
                runner.run("rm -rf {path}")
            runner.run(f"git clone --depth=1 --branch {branch} {url} {path}")
        runner.run(f"git fetch origin {branch}", cwd=path)
        runner.run(f"git checkout --force {branch}", cwd=path)
        runner.run(f"git fetch origin {commit}", cwd=path)
        runner.run(f"git reset --hard {commit}", cwd=path)
        if not os.path.exists(os.path.join(path, "harp00n-run.sh")):
            return "harp00n-run.sh file is missing"
        runner.run(f"sudo /usr/bin/systemctl stop harp00n-8000.service && sleep 2")
        runner.run(f"sudo /usr/bin/systemctl start harp00n-8000.service")
        runner.run(f"ps ux")
        success = True
    except Exception:
        runner.run("/usr/bin/systemctl status harp00n-8000.service", check=False)
        success = False
    return success, runner.output.replace(GITHUB_TOKEN, "****")

@ombott.route('/_harp00n/gitpost', method='GET')
def gitpost():
    return f"/_harp00n/gitpost is setup correctly!"

@ombott.route('/_harp00n/gitpost', method='POST')
def gitpost():
    request = ombott.request
    payload = request.body.read()
    expected_signature = "sha256=" + hmac.new(WEBHOOK_SECRET.encode(), payload, hashlib.sha256).hexdigest()
    signature = request.headers.get('X-Hub-Signature-256', '')
    if not hmac.compare_digest(expected_signature, signature):
        raise ombott.HTTPResponse(body='Invalid signature', status=400)
    data = request.json
    # check the secret
    url = data.get("repository", {}).get("ssh_url")
    branch = data.get("ref", "").split("/", 2)[-1]
    commit = data.get("head_commit", {}).get("id")
    if url and commit and branch == "production":
         with acquire_timeout(LOCK, 30) as acquired:
             if not acquired:
                 raise ombott.HTTPResponse(body='timeout on lock', status=500)
             success, output = upgrade(url, branch, commit, cwd=USR_PATH)
             if not success:
                 raise ombott.HTTPResponse(body=output, status=500)
             return output
    return "nothing to do"

ombott.run(host='localhost', port=8111)
EOF

    echo "==== Configuring systemd to run harp00n.8111 as a service ===="
    cat >/etc/systemd/system/harp00n-8111.service <<EOF
[Unit]
Description=HARP00N Core Service (port 8111)
After=network-online.target
[Service]
ExecStart=uv run --python python3.12 --with "ombott==2.4" $script_path 2>&1 | multilog t s1000000 n10 ${log_path}/8111
Restart=always
User=$username
Environment=PATH=/usr/local/bin:/usr/bin:/bin
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl stop harp00n-8111.service | true
    systemctl start harp00n-8111.service

    echo "==== Configuring systemd to run harp00n.8111 as a service ===="
    cat >/etc/systemd/system/harp00n-8000.service <<EOF
[Unit]
Description=HARP00N User Service (port 8000)
After=network-online.target
[Service]
WorkingDirectory=${usr_path}/checkout
ExecStart=/bin/sh -c "cat harp00n-run.sh | bash -s 2>&1 | multilog t s1000000 n10 ${log_path}/8000"
Restart=always
User=$username
Environment=PATH=/usr/local/bin:/usr/bin:/bin
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}


function register_github_webhook {
    curl -X POST \
	 -H "Authorization: Bearer ${github_token}" \
	 -H "Accept: application/vnd.github+json" \
	 https://api.github.com/repos/${repository}/hooks \
	 -d @- <<EOF
{
  "name": "web",
  "active": true,
  "events": ["push"],
  "config": {
    "url": "https://${domain}/_harp00n/gitpost",
    "content_type": "json",
    "secret": "${webhook_secret}",
    "insecure_ssl": "0"
  }
}
EOF
}


function main {
    display_info

    read_input "domain" "domain name for this machine from DNS"
    read_input "repository" "username/reponame"
    read_input "github_token" "from https://github.com/settings/personal-access-tokens"

    webhook_secret=$(printf "%s" "$github_token" | sha1sum | awk '{print $1}')

    install_dependencies
    install_uv
    create_accounts
    setup_firewall
    setup_domain_name
    setup_caddy_service
    setup_harp00n_services
    register_github_webhook
    display_post_info
}

main
