FROM python:3.13-slim

WORKDIR /app
COPY server.py requirements.txt /app
RUN pip install --no-cache-dir -r requirements.txt
EXPOSE 8091
CMD ["python", "server.py"]
