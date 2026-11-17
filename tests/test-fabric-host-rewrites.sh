#!/usr/bin/env bash
# Renders k8s_coredns_config_host_rewrites (ansible/vars/k8s_init_vars.yaml)
# with ansible itself and checks the result (#183). The list is generated
# from the Fabric network config ui-core writes to the inventory (num_orderers,
# org_names, num_peers, k8s_fabric_network_domain_root), so the test pins:
#   - the default network (3 orderers, org1 with 3 peers) renders exactly the
#     list the file held by hand before #183 (fixtures/fabric-host-rewrites/
#     default-network.json), so the change is a no-op for every project today;
#   - an inventory without those vars renders the same list, so a project
#     whose env.yaml predates them is unchanged;
#   - another network gets one rewrite per orderer and per peer, and one for
#     the org1 CA (fabric_ca.yaml deploys only that CA).
# Needs ansible-playbook on PATH (CI installs ansible-core).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures/fabric-host-rewrites"

if ! command -v ansible-playbook >/dev/null; then
  echo "FAIL: ansible-playbook is not on PATH (pip install ansible-core)" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

cat > "$WORKDIR/render.yaml" <<EOF
---
- name: Render the CoreDNS host rewrites
  hosts: localhost
  connection: local
  gather_facts: false
  vars_files:
    - $ROOT/ansible/vars/k8s_init_vars.yaml
  tasks:
    - name: Write the rendered list as JSON
      ansible.builtin.copy:
        content: "{{ k8s_coredns_config_host_rewrites | to_json }}"
        dest: "{{ out }}"
        mode: "0644"
EOF

FAIL=0

# render <out> <extra vars JSON>: render the list into <out> as JSON.
render() {
  ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_INVENTORY_UNPARSED_WARNING=false \
    ansible-playbook -i localhost, "$WORKDIR/render.yaml" \
    -e "out=$1" -e "$2" >"$WORKDIR/ansible.log" 2>&1 || {
    cat "$WORKDIR/ansible.log" >&2
    return 1
  }
}

# same_json <a> <b>: the two files hold equal JSON values (order matters).
same_json() {
  python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1])) != json.load(open(sys.argv[2])))' "$1" "$2"
}

check() {
  local name="$1" got="$2" want="$3"
  if same_json "$got" "$want"; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name"
    echo "    got:  $(cat "$got")"
    echo "    want: $(cat "$want")"
    FAIL=1
  fi
}

render "$WORKDIR/default.json" \
  '{"num_orderers": 3, "org_names": ["org1"], "num_peers": 3, "k8s_fabric_network_domain_root": "luther.systems"}'
check "default network renders the pre-#183 list" "$WORKDIR/default.json" "$FIXTURES/default-network.json"

# ui-core writes the counts as ints; a string (an older env.yaml, -e on the
# command line) must render the same.
render "$WORKDIR/strings.json" \
  '{"num_orderers": "3", "org_names": ["org1"], "num_peers": "3", "k8s_fabric_network_domain_root": "luther.systems"}'
check "string counts render the same list" "$WORKDIR/strings.json" "$FIXTURES/default-network.json"

render "$WORKDIR/unset.json" '{}'
check "no network vars renders the pre-#183 list" "$WORKDIR/unset.json" "$FIXTURES/default-network.json"

render "$WORKDIR/two-orgs.json" \
  '{"num_orderers": 1, "org_names": ["org1", "org2"], "num_peers": 2, "k8s_fabric_network_domain_root": "example.com"}'
cat > "$WORKDIR/two-orgs-want.json" <<'EOF'
[
  {"query": "orderer0.example.com", "target": "fabric-orderer0.fabric-orderer.svc.cluster.local"},
  {"query": "peer0.org1.example.com", "target": "fabric-peer0-org1.fabric-org1.svc.cluster.local"},
  {"query": "peer1.org1.example.com", "target": "fabric-peer1-org1.fabric-org1.svc.cluster.local"},
  {"query": "peer0.org2.example.com", "target": "fabric-peer0-org2.fabric-org2.svc.cluster.local"},
  {"query": "peer1.org2.example.com", "target": "fabric-peer1-org2.fabric-org2.svc.cluster.local"},
  {"query": "ca.org1.example.com", "target": "fabric-ca.fabric-org1.svc.cluster.local"}
]
EOF
check "1 orderer, 2 orgs of 2 peers" "$WORKDIR/two-orgs.json" "$WORKDIR/two-orgs-want.json"

exit "$FAIL"
