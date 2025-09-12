#!/usr/bin/env python3
import sys
import requests

def main():
    url = "http://localhost:8080/health"
    try:
        response = requests.get(url, timeout=3)
        print(f"Status code: {response.status_code}")
        if response.status_code == 200:
            print("Healthcheck OK")
            sys.exit(0)  # OK
        else:
            print("Healthcheck returned bad status")
            sys.exit(1)  # Mauvais status HTTP
    except Exception as e:
        print(f"Healthcheck failed with exception: {e}")
        sys.exit(1)      # Erreur de connexion ou timeout

if __name__ == "__main__":
    main()
