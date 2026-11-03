// The demo seller agent's API. `/good` delivers what was promised; `/empty` answers 200 {} and takes the money.
import { createServer } from "node:http";

export function startSeller() {
  const server = createServer((req, res) => {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(req.url === "/good" ? JSON.stringify({ rows: [1, 2, 3] }) : "{}");
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      resolve({ url: `http://127.0.0.1:${server.address().port}`, close: () => server.close() });
    });
  });
}
