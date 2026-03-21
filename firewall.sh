#!/bin/bash

echo "A iniciar a configuracao da Firewall..."

# 1. DEFINICAO DE VARIAVEIS
# Interfaces
IF_EXT="ens33" # Internet/NAT  (VM1 IP: 192.168.170.130)
IF_INT="ens36" # Rede Interna  (VM1 IP: 10.10.10.1)

# Redes
NET_INT="10.10.10.0/24" # Rede entre VM1 e VM2

# IPs
IP_ROUTER_EXT="192.168.170.130" # IP externo da VM1
IP_VM2="10.10.10.2"             # VM2 (atacante/cliente)

# 2. MODULOS DO KERNEL
modprobe nf_conntrack_ftp
modprobe nfnetlink_queue

# Activar IP Forwarding
echo 1 >/proc/sys/net/ipv4/ip_forward

# 3. LIMPEZA E POLITICAS POR DEFEITO
# Repor politicas para ACCEPT antes de limpar (evita lock-out)
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Limpar todas as regras e chains
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X

# Definir politicas restritivas
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# 4. LOOPBACK E CONEXOES ESTABELECIDAS
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 5. PROTEGER O ROUTER (INPUT/OUTPUT)
# ICMP (ping) - necessario para testes e diagnostico
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-reply -j ACCEPT
iptables -A OUTPUT -p icmp -j ACCEPT

# DNS - resolucao de nomes para o exterior
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# SSH para o router apenas da rede interna
iptables -A INPUT -p tcp -s $NET_INT --dport 22 -j ACCEPT

# HTTP/HTTPS para o router (actualizacoes, suricata-update, etc.)
iptables -A OUTPUT -p tcp -m multiport --dports 80,443 -j ACCEPT

# 6. SURICATA IPS (NFQUEUE)
# Criada ANTES das regras de FORWARD para inspeccionar tudo
iptables -N SURICATA_INSPECT 2>/dev/null || iptables -F SURICATA_INSPECT

# Inspeccionar todo o trafego que atravessa o router
iptables -A SURICATA_INSPECT -j NFQUEUE --queue-num 0

# Inserir no inicio do FORWARD
iptables -I FORWARD 1 -j SURICATA_INSPECT

# 7. FORWARD - REDE INTERNA PARA O EXTERIOR (com NAT)
# ICMP (ping para o exterior a partir da VM2)
iptables -A FORWARD -s $NET_INT -p icmp -j ACCEPT

# DNS
iptables -A FORWARD -s $NET_INT -o $IF_EXT -p udp --dport 53 -j ACCEPT
iptables -A FORWARD -s $NET_INT -o $IF_EXT -p tcp --dport 53 -j ACCEPT

# HTTP e HTTPS
iptables -A FORWARD -s $NET_INT -o $IF_EXT -p tcp -m multiport --dports 80,443 -j ACCEPT

# SSH para o exterior
iptables -A FORWARD -s $NET_INT -o $IF_EXT -p tcp --dport 22 -j ACCEPT

# FTP (activo e passivo - o modulo nf_conntrack_ftp trata as portas de dados)
iptables -A FORWARD -s $NET_INT -o $IF_EXT -p tcp --dport 21 -j ACCEPT

# 8. NAT - SNAT para a rede interna sair para a Internet
iptables -t nat -A POSTROUTING -s $NET_INT -o $IF_EXT -j SNAT --to-source $IP_ROUTER_EXT

echo "Configuracao de Firewall concluida!"
echo ""
echo "Estado actual das regras:"
iptables -L -n -v --line-numbers
echo ""
echo "NAT:"
iptables -t nat -L -n -v
