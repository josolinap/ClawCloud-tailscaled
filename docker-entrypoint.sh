#!/bin/sh

echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 

unset KUBERNETES_SERVICE_HOST KUBERNETES_PORT KUBERNETES_PORT_443_TCP
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/services.conf
