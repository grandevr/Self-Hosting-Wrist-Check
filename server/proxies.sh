# shellcheck shell=bash
# Wrist Check: config text and paste-in steps for the proxies install.sh doesn't change itself
# (Nginx Proxy Manager, Traefik, Apache, HAProxy, anything else). install.sh downloads this file only
# when one of those is picked, checks it against the checksum built into a release, and sources it.
# It only defines functions that print text: it changes nothing on the machine.
# Uses from install.sh: msg, prefix_path, path_regex, upstream_url and the settings variables.

apache_text() {
  cat <<APACHE
# Wrist Check (install.sh, Apache, ROUTE=$ROUTE): requests for $(prefix_path) without the right token get 404.
# Goes inside the <VirtualHost *:443> for $DOMAIN. Needs mod_rewrite.
RewriteEngine On
RewriteCond "%{HTTP:Authorization}" "!=Bearer $TOKEN"
RewriteRule "$(path_regex)" - [R=404,L]
APACHE
  case "$ROUTE" in
    file) cat <<APACHE
Alias "$STATUS_PATH" "$OUT"
<Directory "$(dirname "$OUT")">
	Require all granted
</Directory>
APACHE
    ;;
    proxy) cat <<APACHE
# Needs mod_proxy_http and mod_headers.
<Location "$(prefix_path)">
	RequestHeader unset Authorization
</Location>
ProxyPass "$(prefix_path)" "$(upstream_url)$(prefix_path)"
ProxyPassReverse "$(prefix_path)" "$(upstream_url)$(prefix_path)"
APACHE
    ;;
  esac
}

haproxy_text() {
  local cond="path $STATUS_PATH"
  [ "${PROTECT:-file}" = folder ] && cond="path_beg $(prefix_path)"
  cat <<HAPROXY
# Wrist Check (install.sh, HAProxy): requests for $(prefix_path) without the right token get 404.
# Goes in the frontend that serves $DOMAIN. Requests with the token go to your usual backend.
http-request deny deny_status 404 if { $cond } !{ req.hdr(authorization) -m str "Bearer $TOKEN" }
HAPROXY
}

traefik_text() {
  local rule="Path(\`$STATUS_PATH\`)"
  [ "${PROTECT:-file}" = folder ] && rule="PathPrefix(\`$(prefix_path)\`)"
  cat <<TRAEFIK
# Wrist Check (install.sh, Traefik file provider, v3 rule syntax; on v2 write Headers( instead of
# Header( and ipWhiteList instead of ipAllowList). Requests for $(prefix_path) with the right token go to
# $(upstream_url); without it Traefik answers 403 (it has no built-in 404 reply).
http:
  routers:
    wrist-check:
      rule: "Host(\`$DOMAIN\`) && $rule && Header(\`Authorization\`, \`Bearer $TOKEN\`)"
      priority: 10001
      tls: {}
      middlewares: [wrist-check-strip]
      service: wrist-check
    wrist-check-denied:
      rule: "Host(\`$DOMAIN\`) && $rule"
      priority: 10000
      tls: {}
      middlewares: [wrist-check-deny]
      service: noop@internal
  middlewares:
    wrist-check-strip:
      headers:
        customRequestHeaders:
          Authorization: ""
    wrist-check-deny:
      ipAllowList:
        sourceRange: ["127.0.0.1/32"]
  services:
    wrist-check:
      loadBalancer:
        servers:
          - url: "$(upstream_url)"
TRAEFIK
}

other_text() {
  cat <<OTHER
# Wrist Check: the rule for any web server or proxy in front of $DOMAIN.
#   Requests for $(prefix_path)
#   with the header   Authorization: Bearer $TOKEN   -> handle as usual (pass on, or serve the file)
#   without it                                      -> answer 404
OTHER
}

# Steps after printing the lines. $1 = step number to start at.
proxy_steps() {
  local n=$1
  case "$PROXY" in
    npm)
      msg "  $n. In Nginx Proxy Manager: Hosts > Proxy Hosts > $DOMAIN > Edit > Advanced. Paste the lines above"
      msg "     into \"Custom Nginx Configuration\" and save (NPM checks the config when you save)." ;;
    traefik)
      msg "  $n. Save the lines above as a .yml file in the folder Traefik's file provider watches"
      msg "     (providers.file.directory, e.g. /etc/traefik/dynamic/wrist-check.yml). Traefik loads it by itself." ;;
    apache)
      msg "  $n. Paste the lines above inside the <VirtualHost *:443> for $DOMAIN."
      msg "     Turn on the modules they use: sudo a2enmod rewrite$([ "$ROUTE" = proxy ] && echo ' proxy_http headers')"
      msg "  $((n + 1)). Check and reload:  sudo apachectl configtest && sudo systemctl reload apache2" ;;
    haproxy)
      msg "  $n. Paste the line above into the frontend that serves $DOMAIN, before its use_backend lines."
      msg "  $((n + 1)). Check and reload:  sudo haproxy -c -f /etc/haproxy/haproxy.cfg && sudo systemctl reload haproxy" ;;
    other)
      msg "  $n. Set up that rule in your web server or proxy." ;;
  esac
}
