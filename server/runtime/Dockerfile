FROM python@sha256:b18b261e1b4974b4f321451ad5251ded85abb22c2b8b262da527dda1d031ab30
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app/runtime
COPY runtime/requirements.txt /app/runtime/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt && useradd --uid 10001 --no-create-home app
COPY contracts /app/contracts
COPY runtime/weekglass_server /app/runtime/weekglass_server
USER 10001:10001
EXPOSE 8000
CMD ["uvicorn", "weekglass_server.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--limit-concurrency", "16", "--timeout-keep-alive", "5", "--no-access-log"]
