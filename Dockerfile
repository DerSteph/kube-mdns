FROM python:3.10-alpine

RUN apk add --no-cache rust cargo

RUN adduser -u 1000 -D nonrootuser

WORKDIR /usr/src/app

COPY --chown=nonrootuser:nonrootuser requirements.txt ./

ADD --chown=nonrootuser:nonrootuser src src

ENV PYTHONPATH="$PYTHONPATH:/usr/src/app"

USER nonrootuser

RUN pip install --no-cache-dir -r requirements.txt

ENTRYPOINT [ "python", "src/main.py" ]