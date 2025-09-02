#!/bin/sh

unset KUBERNETES_SERVICE_HOST KUBERNETES_PORT KUBERNETES_PORT_443_TCP
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/services.conf
