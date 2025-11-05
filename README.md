# Interactive Brokers Gateway

Docker setup for Interactive Brokers Gateway, enabling API access to IB trading accounts.

## Features

- IB Gateway running in Docker container
- Support for both paper and live trading
- VNC access for GUI management
- Automatic connection management
- Two-factor authentication support

## Prerequisites

- Docker and Docker Compose installed
- Interactive Brokers account
- IB API access enabled in your account

## Setup

1. **Copy environment file:**
   ```bash
   cp .env.example $HOME/projects/secrets/ibgateway.env
   ```

2. **Configure credentials:**
   Edit `$HOME/projects/secrets/ibgateway.env` and set your IB credentials:
   ```bash
   IB_USERNAME=your_username
   IB_PASSWORD=your_password
   TRADING_MODE=paper  # or 'live'
   READ_ONLY_API=no
   ```

3. **Deploy:**
   ```bash
   ./deploy.sh
   ```

## Ports

- `4001`: Live trading API port
- `4002`: Paper trading API port
- `5900`: VNC port (GUI access)

## Usage

### Connect via API

For paper trading:
```python
from ib_insync import IB

ib = IB()
ib.connect('localhost', 4002, clientId=1)
```

For live trading:
```python
ib.connect('localhost', 4001, clientId=1)
```

### Access GUI via VNC

Connect to `localhost:5900` with a VNC client using the password set in `VNC_PASSWORD`.

## Configuration

### Environment Variables

- `IB_USERNAME`: Your IB username
- `IB_PASSWORD`: Your IB password
- `TRADING_MODE`: `paper` or `live`
- `READ_ONLY_API`: `yes` or `no`
- `VNC_PASSWORD`: VNC access password (optional)
- `TWOFA_TIMEOUT_ACTION`: Action on 2FA timeout (`restart`, `exit`)

## Management

### View logs
```bash
docker compose logs -f
```

### Restart service
```bash
docker compose restart
```

### Stop service
```bash
docker compose down
```

## Security Notes

⚠️ **Important Security Considerations:**

1. **Network exposure**: By default, ports are only exposed to localhost
2. **Credentials**: Never commit `.env` file to version control
3. **API security**: IB API uses unencrypted TCP - use SSH tunnels for remote access
4. **2FA**: Enable two-factor authentication on your IB account

## Troubleshooting

### Connection issues
- Verify IB Gateway is running: `docker compose ps`
- Check logs: `docker compose logs -f`
- Ensure API access is enabled in IB account settings

### Authentication failures
- Verify credentials in `.env`
- Check 2FA settings
- Review IB account security settings

## References

- [IB Gateway Documentation](https://www.interactivebrokers.com/en/trading/ibgateway-stable.php)
- [Docker Image Source](https://github.com/gnzsnz/ib-gateway-docker)
- [IB API Documentation](https://interactivebrokers.github.io/tws-api/)
