import re
import asyncio
from aiohttp import web
from enum import Enum

class Command(Enum):
    GET_TELEMETRY = 0

    def encode(self):
        return bytes([self.value])

class Status(Enum):
    SUCCESS = 0
    UNKNOWN_COMMAND = 1

    def encode(self):
        return bytes([self.value])

class TelemetryStore:
    def __init__(self):
        self.metrics_ = []

    def add_message(self, metrics: str):
        self.metrics_.append(metrics)

    @property
    def metrics(self):
        # cleanup labels and reset storage
        # it should also merge counters and histograms here, as they might be duplicated
        # after removing user agents and differences between websocket polling and Prometheus
        # scrapping interval
        current_metrics = [re.sub(r'agent="[^"]*",?', '', line) for line in self.metrics_]
        self.metrics_ = []
        return current_metrics

# Poll telemetry data and send it through websocket
async def poll_app_telemetry(ws, store: TelemetryStore):
    try:
        while True:
            await asyncio.sleep(1) # poll interval

            await ws.send_bytes(Command.GET_TELEMETRY.encode())
            # wait for 1 second the client to respond
            message = await asyncio.wait_for(ws.receive(), timeout=1)
            if message.type == web.WSMsgType.BINARY:
                match Status(message.data[0]):
                    case Status.SUCCESS:
                        store.add_message(message.data[1:].decode('utf-8'))
                    case Status.UNKNOWN_COMMAND:
                        print("The client does not understand GET_TELEMETRY")
                        break
            else:
                print("Expected BINARY response from the client. Ignoring")
                break
    except asyncio.TimeoutError:
        print("Timeout: No message received within the specified time.")
        await ws.close()
    except asyncio.CancelledError:
        print("Polling task cancelled.")
    except Exception as e:
        print(f"Error in websocket: {e}")
    finally:
        await ws.close()
        print("WebSocket closed.")

async def poll_echo(ws):
    try:
        async for msg in ws:
            print(f"INCOMING: {msg.type}")
            if msg.type == web.WSMsgType.TEXT:
                print(f"TEXT: {msg.data}")
                await ws.send_str(msg.data)
            elif msg.type == web.WSMsgType.BINARY:
                print(f"BINARY: {msg.data.decode('utf-8')}")
                await ws.send_bytes(msg.data)
            elif msg.type == web.WSMsgType.CLOSE:
                print("CLOSE")
                break
    except asyncio.TimeoutError:
        print("Timeout: No message received within the specified time.")
        await ws.close()
    except asyncio.CancelledError:
        print("Polling task cancelled.")
    except Exception as e:
        print(f"Error in websocket: {e}")
    finally:
        await ws.close()
        print("WebSocket closed.")


# WebSocket handler for connection upgrades
async def websocket_handler(request, store: TelemetryStore):
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    await poll_app_telemetry(ws, store)
    return ws

async def echo_handler(request):
    print("start echo_handler")
    ws = web.WebSocketResponse(heartbeat = 3.0)
    await ws.prepare(request)
    await poll_echo(ws)
    return ws

# REST API to get telemetry metrics
async def metrics(request, store: TelemetryStore):
    return web.Response(
        body="\n".join(store.metrics),
        content_type="text/plain; version=0.0.4"
    )

# Initialize app with routes
async def init_app():
    store = TelemetryStore()
    app = web.Application()
    app.router.add_get('/metrics', lambda request: metrics(request, store))
    app.router.add_get('/_appTelemetry', lambda request: websocket_handler(request, store))
    app.router.add_get('/echo', lambda request: echo_handler(request))
    return app

# Run the application
if __name__ == '__main__':
    app = asyncio.run(init_app())
    web.run_app(app, host='0.0.0.0', port=8091)
