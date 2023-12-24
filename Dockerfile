FROM python:3.10-alpine as builder
RUN apk add --no-cache cargo
ENV CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse
RUN pip wheel --wheel-dir /wheels 'jsonschema==4.20.0'

FROM python:3.10-alpine

COPY --from=builder /wheels /wheels

RUN adduser -u 1000 -D nonrootuser

WORKDIR /usr/src/app

COPY --chown=nonrootuser:nonrootuser requirements.txt ./

ENV PYTHONPATH="$PYTHONPATH:/usr/src/app"

USER nonrootuser

RUN pip install --no-cache-dir --find-links /wheels 'jsonschema==4.20.0' --pre -r requirements.txt

ADD --chown=nonrootuser:nonrootuser src src

ENTRYPOINT [ "python", "src/main.py" ]