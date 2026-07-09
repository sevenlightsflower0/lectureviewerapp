const functions = require("firebase-functions");
const https = require("https");
const cors = require("cors")({origin: true});

exports.sseProxy = functions.https.onRequest((req, res) => {
  cors(req, res, () => {
    const channel = req.query.channel;
    if (!channel) {
      res.status(400).send("Missing channel parameter");
      return;
    }

    const targetUrl = `https://lt2srv.iar.kit.edu/webapi/stream?channel=${encodeURIComponent(channel)}`;

    const request = https.get(targetUrl, (response) => {
      res.writeHead(200, {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
      });

      response.on("data", (chunk) => {
        res.write(chunk);
      });
      response.on("end", () => {
        res.end();
      });
    });

    request.on("error", (err) => {
      console.error("Proxy error:", err);
      res.status(500).send("Proxy error");
    });
  });
});
