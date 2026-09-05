FROM python:3.11-alpine

WORKDIR /app
COPY tailscale_sd.py /app/tailscale_sd.py
RUN chmod +x /app/tailscale_sd.py

EXPOSE 8080

ENTRYPOINT ["python3", "/app/tailscale_sd.py"]
CMD ["--serve", "--port", "8080"]
