#!/bin/bash
echo "A iniciar a configuracao da Firewall..."

#
# 1. DEFINICAO DE VARIAVEIS
# Interfaces
IF_EXT="ens33"       # Internet/NAT  (IP externo: 87.248.214.97)
IF_DMZ="ens36"       # DMZ           (IP router DMZ: 23.214.219.254)
IF_INT="ens37"       # Rede Interna  (IP router INT: 192.168.10.254)

# Redes
NET_DMZ="23.214.219.128/25"   # Rede DMZ (IPs publicos — sem SNAT)
NET_INT="192.168.10.0/24"     # Rede Interna (IPs privados — com SNAT)

# IPs do router
IP_ROUTER_EXT="87.248.214.97"    # IP externo da firewall (Internet)
IP_ROUTER_DMZ="23.214.219.254"   # IP do router na DMZ
IP_ROUTER_INT="192.168.10.254"   # IP do router na rede interna

# IPs dos servidores na DMZ
IP_DNS="23.214.219.130"      # Servidor DNS
IP_SMTP="23.214.219.131"     # Servidor SMTP
IP_MAIL="23.214.219.132"     # Servidor de correio (POP/IMAP)
IP_WWW="23.214.219.133"      # Servidor Web (HTTP/HTTPS)
IP_VPN_GW="23.214.219.134"   # Gateway VPN (vpn-gw)

# IPs dos servidores na Rede Interna
IP_FTP="192.168.10.10"       # Servidor FTP
IP_DATASTORE="192.168.10.11" # Servidor datastore

# IPs externos autorizados (Internet)
IP_DNS2="193.137.16.75"      # Servidor DNS2 externo (dns.uminho.pt)
IP_EDEN="193.136.212.1"      # Servidor eden externo

#
# 2. MODULOS DO KERNEL
modprobe nf_conntrack_ftp
modprobe nfnetlink_queue

# Activar IP Forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

#
# 3. LIMPEZA E POLITICAS POR DEFEITO
# Repor para ACCEPT antes de limpar (evita lock-out durante a execucao)
iptables -P INPUT   ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT  ACCEPT

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X

# Politicas restritivas por defeito
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

#
# 4. LOOPBACK E CONEXOES ESTABELECIDAS / RELACIONADAS
iptables -A INPUT   -i lo -j ACCEPT
iptables -A OUTPUT  -o lo -j ACCEPT

# Trafego de conexoes ja estabelecidas ou relacionadas
# Cobre respostas DNS, dados FTP passivo/activo (via nf_conntrack_ftp),
# respostas ICMP de erro, etc.
iptables -A INPUT   -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

#
# 5. SURICATA IPS (NFQUEUE)
# Inserido no inicio do FORWARD para inspeccionar todo o trafego
# antes de qualquer regra de ACCEPT.
# --queue-bypass: fail-open se o Suricata nao estiver a correr.
# Remover esta opcao para comportamento fail-closed (mais seguro).
iptables -N SURICATA_INSPECT 2>/dev/null || iptables -F SURICATA_INSPECT
iptables -A SURICATA_INSPECT -j NFQUEUE --queue-num 0 --queue-bypass
iptables -I FORWARD 1 -j SURICATA_INSPECT

#
# 6. PROTEGER O ROUTER (INPUT / OUTPUT)
#
# Requisito: DROP tudo excepto:
#   - DNS para servidores externos (resolucao de nomes do proprio router)
#   - SSH da rede interna ou do vpn-gw

# --- INPUT: SSH para o router ---
# Da rede interna (qualquer host)
iptables -A INPUT -i $IF_INT -p tcp -s $NET_INT --dport 22 -j ACCEPT
# Do gateway VPN (na DMZ)
iptables -A INPUT -i $IF_DMZ -p tcp -s $IP_VPN_GW --dport 22 -j ACCEPT

# --- OUTPUT: DNS ---
# Para servidores externos (resolucao de nomes do router para o exterior)
iptables -A OUTPUT -o $IF_EXT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -o $IF_EXT -p tcp --dport 53 -j ACCEPT
# Para o servidor DNS interno na DMZ (caso o router use o dns interno)
iptables -A OUTPUT -o $IF_DMZ -p udp -d $IP_DNS --dport 53 -j ACCEPT
iptables -A OUTPUT -o $IF_DMZ -p tcp -d $IP_DNS --dport 53 -j ACCEPT

# --- OUTPUT: HTTP/HTTPS para actualizacoes do sistema e suricata-update ---
iptables -A OUTPUT -o $IF_EXT -p tcp -m multiport --dports 80,443 -j ACCEPT

#
# 7. DNAT — conexoes externas para o IP do router redirecionadas
#    para servidores internos (NAT de destino, PREROUTING)
#
# Requisito:
#   - FTP (activo e passivo) → ftp server (rede interna)
#   - SSH → datastore, mas so de eden ou dns2

# --- DNAT: FTP → ftp server na rede interna ---
# O modulo nf_conntrack_ftp trata automaticamente as portas de dados
# para FTP activo (porta 20) e passivo (portas altas), criando
# entradas RELATED que sao cobertas pela regra ESTABLISHED,RELATED.
iptables -t nat -A PREROUTING -i $IF_EXT -p tcp --dport 21 \
    -j DNAT --to-destination $IP_FTP:21

# --- DNAT: SSH → datastore, apenas de eden ou dns2 ---
iptables -t nat -A PREROUTING -i $IF_EXT -p tcp -s $IP_EDEN \
    --dport 22 -j DNAT --to-destination $IP_DATASTORE:22
iptables -t nat -A PREROUTING -i $IF_EXT -p tcp -s $IP_DNS2 \
    --dport 22 -j DNAT --to-destination $IP_DATASTORE:22

#
# 8. FORWARD — comunicacoes directas entre redes (sem NAT)
#
# Nota: o ESTABLISHED,RELATED da seccao 4 cobre todas as respostas,
# por isso so e necessario permitir o sentido de inicio de cada ligacao.

# --- a) DNS: clientes (rede interna) → dns server (DMZ) ---
iptables -A FORWARD -i $IF_INT -o $IF_DMZ \
    -p udp -d $IP_DNS --dport 53 -j ACCEPT
iptables -A FORWARD -i $IF_INT -o $IF_DMZ \
    -p tcp -d $IP_DNS --dport 53 -j ACCEPT

# --- b) DNS: dns server → Internet (resolucao recursiva) ---
iptables -A FORWARD -i $IF_DMZ -o $IF_EXT \
    -p udp -s $IP_DNS --dport 53 -j ACCEPT
iptables -A FORWARD -i $IF_DMZ -o $IF_EXT \
    -p tcp -s $IP_DNS --dport 53 -j ACCEPT

# --- c) Sincronizacao de zonas DNS: dns (DMZ) ↔ dns2 (Internet) ---
# dns → dns2 (transferencia de zona iniciada pelo dns interno)
iptables -A FORWARD -i $IF_DMZ -o $IF_EXT \
    -p tcp -s $IP_DNS -d $IP_DNS2 --dport 53 -j ACCEPT
# dns2 → dns (transferencia de zona iniciada pelo dns2 externo)
iptables -A FORWARD -i $IF_EXT -o $IF_DMZ \
    -p tcp -s $IP_DNS2 -d $IP_DNS --dport 53 -j ACCEPT

# --- d) SMTP: ligacoes ao smtp server ---
# Do exterior (Internet) → smtp server (recepcao de correio)
iptables -A FORWARD -i $IF_EXT -o $IF_DMZ \
    -p tcp -d $IP_SMTP --dport 25 -j ACCEPT
# Da rede interna → smtp server (envio de correio pelos utilizadores internos)
iptables -A FORWARD -i $IF_INT -o $IF_DMZ \
    -p tcp -d $IP_SMTP --dport 25 -j ACCEPT
# smtp server → exterior (entrega de correio para servidores externos)
iptables -A FORWARD -i $IF_DMZ -o $IF_EXT \
    -p tcp -s $IP_SMTP --dport 25 -j ACCEPT

# --- e) POP3/IMAP: ligacoes ao mail server ---
# Do exterior
iptables -A FORWARD -i $IF_EXT -o $IF_DMZ \
    -p tcp -d $IP_MAIL -m multiport --dports 110,143,993,995 -j ACCEPT
# Da rede interna
iptables -A FORWARD -i $IF_INT -o $IF_DMZ \
    -p tcp -d $IP_MAIL -m multiport --dports 110,143,993,995 -j ACCEPT

# --- f) HTTP/HTTPS: ligacoes ao www server ---
# Do exterior
iptables -A FORWARD -i $IF_EXT -o $IF_DMZ \
    -p tcp -d $IP_WWW -m multiport --dports 80,443 -j ACCEPT
# Da rede interna
iptables -A FORWARD -i $IF_INT -o $IF_DMZ \
    -p tcp -d $IP_WWW -m multiport --dports 80,443 -j ACCEPT

# --- g) OpenVPN: exterior → vpn-gw (DMZ) ---
iptables -A FORWARD -i $IF_EXT -o $IF_DMZ \
    -p udp -d $IP_VPN_GW --dport 1194 -j ACCEPT

# --- h) Clientes VPN → rede interna (via vpn-gw com MASQUERADE) ---
# O vpn-gw faz SNAT/MASQUERADE para os clientes VPN, por isso
# o trafego chega ao router com source = IP_VPN_GW.
# Os requisitos dizem "todos os servicos da rede interna".
iptables -A FORWARD -i $IF_DMZ -o $IF_INT \
    -s $IP_VPN_GW -j ACCEPT

# --- i) FTP externo → ftp server na rede interna (via DNAT seccao 7) ---
iptables -A FORWARD -i $IF_EXT -o $IF_INT \
    -p tcp -d $IP_FTP --dport 21 -j ACCEPT

# --- j) SSH externo (eden/dns2) → datastore (via DNAT seccao 7) ---
iptables -A FORWARD -i $IF_EXT -o $IF_INT \
    -p tcp -s $IP_EDEN -d $IP_DATASTORE --dport 22 -j ACCEPT
iptables -A FORWARD -i $IF_EXT -o $IF_INT \
    -p tcp -s $IP_DNS2 -d $IP_DATASTORE --dport 22 -j ACCEPT

#
# 9. FORWARD — rede interna para o exterior (com NAT, seccao 10)
#
# Requisito: DNS, HTTP, HTTPS, SSH e FTP (activo e passivo)

# DNS
iptables -A FORWARD -i $IF_INT -o $IF_EXT \
    -p udp --dport 53 -j ACCEPT
iptables -A FORWARD -i $IF_INT -o $IF_EXT \
    -p tcp --dport 53 -j ACCEPT

# HTTP, HTTPS e SSH
iptables -A FORWARD -i $IF_INT -o $IF_EXT \
    -p tcp -m multiport --dports 80,443,22 -j ACCEPT

# FTP (activo e passivo — nf_conntrack_ftp trata as portas de dados via RELATED)
iptables -A FORWARD -i $IF_INT -o $IF_EXT \
    -p tcp --dport 21 -j ACCEPT

#
# 10. NAT — SNAT para a rede interna sair para a Internet
#
# Nota: a DMZ usa IPs publicos reais (23.214.219.x) e NAO precisa de SNAT.
# O trafego da DMZ para o exterior sai com o IP real de cada servidor,
# o que e necessario para SMTP (SPF/PTR), DNS e outros protocolos.
# Apenas a rede interna (192.168.10.0/24) precisa de SNAT.
iptables -t nat -A POSTROUTING -s $NET_INT -o $IF_EXT \
    -j SNAT --to-source $IP_ROUTER_EXT

echo ""
echo "Configuracao de Firewall concluida!"
echo ""
echo "=== FILTER ==="
iptables -L -n -v --line-numbers
echo ""
echo "=== NAT ==="
iptables -t nat -L -n -v
