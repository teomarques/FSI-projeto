#!/bin/bash

echo "A iniciar a configuracao da Firewall..."

# ==============================================================================
# 1. DEFINICAO DE VARIAVEIS (Baseado na Figura 1)
# ==============================================================================
# Interfaces de Rede
IF_EXT="ens33"      # Internet (IP Externo Firewall: 87.248.214.97)
IF_DMZ="ens36"      # DMZ (IP Router: 23.214.219.254)
IF_INT="ens37"      # Internal Network (IP Router: 192.168.10.254)

# Redes
NET_DMZ="23.214.219.128/25"
NET_INT="192.168.10.0/24"

# IPs do Router
IP_ROUTER_EXT="87.248.214.97"
IP_ROUTER_DMZ="23.214.219.254"
IP_ROUTER_INT="192.168.10.254"

# Servidores na DMZ (IPs atribuidos manualmente dentro da sub-rede /25)
IP_DNS="23.214.219.130"
IP_SMTP="23.214.219.131"
IP_MAIL="23.214.219.132"
IP_WWW="23.214.219.133"
IP_VPN_GW="23.214.219.134"

# Servidores na Rede Interna (IPs atribuidos manualmente dentro da sub-rede /24)
IP_FTP="192.168.10.10"
IP_DATASTORE="192.168.10.11"

# Servidores Externos (Internet)
IP_DNS2="193.137.16.75"
IP_EDEN="193.136.212.1"

# ==============================================================================
# 2. CARREGAR MODULOS DO KERNEL (O "Truque" do FTP)
# ==============================================================================
# O FTP usa portas dinamicas para dados. Este modulo diz ao IPTables para 
# ler os pacotes de controlo e abrir as portas de dados automaticamente.
modprobe nf_conntrack_ftp

# Ativar IP Forwarding (Garantir que o Linux atua como Router)
echo 1 > /proc/sys/net/ipv4/ip_forward

# ==============================================================================
# 3. LIMPEZA E POLITICAS POR DEFEITO (DROP)
# ==============================================================================
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X

# Definir politicas restritivas
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Permitir Loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Permitir trafego de retorno para conexoes estabelecidas
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# ==============================================================================
# 4. PROTEGER O ROUTER (INPUT / OUTPUT)
# ==============================================================================
# Autorizar pedidos de resolucao de nomes (DNS) enviados para o exterior
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Autorizar SSH para o router se originado na rede interna ou na VPN Gateway
iptables -A INPUT -p tcp -s $NET_INT --dport 22 -j ACCEPT
iptables -A INPUT -p tcp -s $IP_VPN_GW --dport 22 -j ACCEPT

# ==============================================================================
# 5. COMUNICACOES DIRETAS (SEM NAT) -> FORWARD
# ==============================================================================
# DNS (Resolucao de nomes do dns server para a Internet e sincronizacao)
iptables -A FORWARD -p udp -s $IP_DNS --dport 53 -j ACCEPT
iptables -A FORWARD -p tcp -s $IP_DNS --dport 53 -j ACCEPT
iptables -A FORWARD -p tcp -s $IP_DNS -d $IP_DNS2 --dport 53 -j ACCEPT
iptables -A FORWARD -p tcp -s $IP_DNS2 -d $IP_DNS --dport 53 -j ACCEPT

# SMTP para o servidor smtp
iptables -A FORWARD -p tcp -d $IP_SMTP --dport 25 -j ACCEPT

# POP e IMAP para o mail server (Portas 110/995 POP, 143/993 IMAP)
iptables -A FORWARD -p tcp -d $IP_MAIL -m multiport --dports 110,995,143,993 -j ACCEPT

# HTTP e HTTPS para o www server
iptables -A FORWARD -p tcp -d $IP_WWW -m multiport --dports 80,443 -j ACCEPT

# OpenVPN para o vpn-gw server (Por defeito porta UDP 1194)
iptables -A FORWARD -p udp -d $IP_VPN_GW --dport 1194 -j ACCEPT

# Clientes VPN para a Rede Interna (Assumindo que o vpn-gw faz SNAT)
iptables -A FORWARD -s $IP_VPN_GW -d $NET_INT -j ACCEPT

# ==============================================================================
# 6. LIGACOES DO EXTERIOR PARA O ROUTER (DNAT)
# ==============================================================================
# FTP (Activo e Passivo) para o servidor ftp interno
iptables -t nat -A PREROUTING -p tcp -d $IP_ROUTER_EXT --dport 21 -j DNAT --to-destination $IP_FTP
iptables -A FORWARD -p tcp -d $IP_FTP --dport 21 -j ACCEPT
# (O modulo nf_conntrack_ftp carregado no inicio trata das portas de dados dinâmicas)

# SSH para o datastore, mas APENAS se originado no eden ou dns2
iptables -t nat -A PREROUTING -p tcp -d $IP_ROUTER_EXT -s $IP_EDEN --dport 22 -j DNAT --to-destination $IP_DATASTORE
iptables -t nat -A PREROUTING -p tcp -d $IP_ROUTER_EXT -s $IP_DNS2 --dport 22 -j DNAT --to-destination $IP_DATASTORE
iptables -A FORWARD -p tcp -d $IP_DATASTORE --dport 22 -j ACCEPT

# ==============================================================================
# 7. COMUNICACOES DA REDE INTERNA PARA O EXTERIOR (SNAT)
# ==============================================================================
# Mascarar os pacotes da rede interna a sair para a Internet (NAT)
iptables -t nat -A POSTROUTING -s $NET_INT -o $IF_EXT -j SNAT --to-source $IP_ROUTER_EXT

# Autorizar os pacotes a atravessar o router (FORWARD) para os servicos pedidos
iptables -A FORWARD -s $NET_INT -o $IF_EXT -p udp --dport 53 -j ACCEPT
iptables -A FORWARD -s $NET_INT -o $IF_EXT -p tcp -m multiport --dports 53,80,443,22,21 -j ACCEPT

echo "Configuracao de Firewall e NAT concluida!"
