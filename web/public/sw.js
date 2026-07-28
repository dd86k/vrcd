/* vrcd service worker.
 *
 * This exists so a browser will install the page as an app, not to make vrcd
 * work offline: every screen is a view of state that arrives over the
 * WebSocket, and with no link to the server there is nothing truthful to show.
 * So the cache holds the shell and nothing else, and it is only reached for
 * when the network has already failed.
 *
 * Network-first is deliberate. The document root re-reads a file as soon as
 * its mtime moves, which is what makes editing app.css an edit plus a refresh;
 * a cache-first worker would undo that by serving the previous file for one
 * more load after every edit.
 *
 * Bump CACHE when the shell list changes -- activate drops every other cache,
 * which is how a stale worker's leftovers get collected.
 */

var CACHE = "vrcd-shell-v1";

/* Only the files a cold start needs. The pages themselves are cached as they
   are visited: "/" answers a redirect when there is no session, and a cached
   redirect cannot be replayed for a navigation. */
var SHELL = [
    "/static/app.css",
    "/static/app.js",
    "/static/icon-512.png",
    "/manifest.webmanifest"
];

self.addEventListener("install", function (ev) {
    ev.waitUntil(caches.open(CACHE).then(function (cache) {
        return cache.addAll(SHELL);
    }).then(function () {
        return self.skipWaiting();
    }));
});

self.addEventListener("activate", function (ev) {
    ev.waitUntil(caches.keys().then(function (names) {
        return Promise.all(names.map(function (name) {
            return name === CACHE ? Promise.resolve(false) : caches.delete(name);
        }));
    }).then(function () {
        return self.clients.claim();
    }));
});

/* A response is only worth keeping when it is this origin's own, came back OK,
   and was not the end of a redirect chain: replaying a redirected response for
   a navigation is an error, and the sign-in redirect is exactly that. */
function cacheable(res) {
    return res && res.ok && res.type === "basic" && res.redirected === false;
}

function offline(req) {
    return caches.match(req).then(function (hit) {
        if (hit) return hit;
        if (req.mode === "navigate")
            return caches.match("/").then(function (shell) {
                return shell || new Response("vrcd is offline.", {
                    status: 503,
                    headers: { "Content-Type": "text/plain; charset=utf-8" }
                });
            });
        return Response.error();
    });
}

self.addEventListener("fetch", function (ev) {
    var req = ev.request;
    if (req.method !== "GET")
        return;

    var url = new URL(req.url);
    if (url.origin !== self.location.origin)
        return;

    /* The API is live state and the image proxy answers 202 while a download
       is still in flight: neither survives being served from a cache. The
       worker script and the sign-in page are left to the browser so a stale
       copy can never wedge an update or a session. */
    if (url.pathname.lastIndexOf("/api/", 0) === 0 ||
        url.pathname.lastIndexOf("/ws/", 0) === 0 ||
        url.pathname === "/login" || url.pathname === "/sw.js")
        return;

    ev.respondWith(fetch(req).then(function (res) {
        if (cacheable(res)) {
            var copy = res.clone();
            ev.waitUntil(caches.open(CACHE).then(function (cache) {
                return cache.put(req, copy);
            }));
        }
        return res;
    }).catch(function () {
        return offline(req);
    }));
});
