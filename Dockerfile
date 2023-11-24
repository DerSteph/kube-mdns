FROM python:3.10-slim

WORKDIR /usr/src/app

COPY requirements.txt ./

RUN pip install --no-cache-dir -r requirements.txt

ADD src src

ENV PYTHONPATH="$PYTHONPATH:/usr/src/app"

ENTRYPOINT [ "python", "src/main.py" ]