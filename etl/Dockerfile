FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY etl.py schema.sql ./
USER nobody
CMD ["python", "etl.py"]
