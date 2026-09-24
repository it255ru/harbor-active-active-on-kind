# PostgreSQL + Patroni image (backlog H2.2). No maintained upstream image exists
# (Spilo's last release is 2023), so Patroni is layered on the pinned PostgreSQL image.
FROM postgres:18.6-alpine3.24@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873

RUN apk add --no-cache python3 curl \
 && python3 -m venv /opt/patroni
COPY constraints.txt /tmp/constraints.txt
RUN /opt/patroni/bin/pip install --no-cache-dir -c /tmp/constraints.txt 'patroni[consul,psycopg3]==4.1.5' \
 && rm /tmp/constraints.txt

ENV PATH=/opt/patroni/bin:$PATH
USER postgres
ENTRYPOINT ["patroni"]
CMD ["/etc/patroni/patroni.yml"]
