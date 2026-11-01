// Access control for the API server: an optional API key and an optional
// source-IP allowlist. Loopback clients (the local web UI, notify.py) are
// always allowed. With neither option set every client is allowed.
//
// Pure module: requiring it has no side effects, so it can be unit tested.

var crypto = require('crypto');
var net = require('net');

// Canonical form of a peer address for matching: lower-case, IPv6 zone id
// removed, and IPv4-mapped IPv6 (::ffff:a.b.c.d, as seen on a dual-stack
// listener) reduced to plain IPv4. Returns '' for anything that isn't a string.
function normalizeAddress(addr) {
  if (typeof addr !== 'string') return '';
  addr = addr.trim().toLowerCase();
  var zone = addr.indexOf('%');
  if (zone !== -1) addr = addr.slice(0, zone);
  var mapped = /^::ffff:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/.exec(addr);
  return mapped ? mapped[1] : addr;
}

// True for loopback addresses as reported by req.socket.remoteAddress:
// IPv4 127.0.0.0/8, IPv6 ::1, and IPv4-mapped ::ffff:127.x.x.x.
function isLoopbackAddress(addr) {
  addr = normalizeAddress(addr);
  if (addr === '::1') return true;
  return /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(addr);
}

function ipType(addr) {
  return net.isIPv6(addr) ? 'ipv6' : 'ipv4';
}

// Parse a comma-separated list of IPs and CIDR ranges (IPv4 or IPv6), e.g.
// "192.168.1.0/24, 10.0.0.5, fd00::/8". Returns null when the list is empty,
// otherwise { size, check(addr) }. Throws on the first invalid entry.
function parseAllowList(csv) {
  var entries = String(csv || '').split(/[\s,]+/).filter(Boolean);
  if (entries.length === 0) return null;

  var list = new net.BlockList();
  entries.forEach(function(entry) {
    var slash = entry.indexOf('/');
    var addr = slash === -1 ? entry : entry.slice(0, slash);
    var prefix = slash === -1 ? null : entry.slice(slash + 1);
    addr = prefix === null ? normalizeAddress(addr) : addr.toLowerCase();

    var family = net.isIP(addr);
    if (!family) {
      throw new Error('Invalid ALLOWED_IPS entry "' + entry + '": not an IP address');
    }
    var type = family === 6 ? 'ipv6' : 'ipv4';

    if (prefix === null) {
      list.addAddress(addr, type);
      return;
    }
    var bits = /^\d{1,3}$/.test(prefix) ? parseInt(prefix, 10) : NaN;
    if (!(bits >= 0 && bits <= (family === 6 ? 128 : 32))) {
      throw new Error('Invalid ALLOWED_IPS entry "' + entry + '": bad prefix length');
    }
    list.addSubnet(addr, bits, type);
  });

  return {
    size: entries.length,
    check: function(addr) {
      addr = normalizeAddress(addr);
      if (!net.isIP(addr)) return false;
      return list.check(addr, ipType(addr));
    }
  };
}

function sha256(value) {
  return crypto.createHash('sha256').update(value, 'utf8').digest();
}

// Constant-time string comparison. Hashing both sides first gives equal-length
// buffers (timingSafeEqual throws otherwise) and hides the secret's length.
function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  return crypto.timingSafeEqual(sha256(a), sha256(b));
}

// The key a client presented, from "Authorization: Bearer <key>" or
// "X-API-Key: <key>". Returns null when neither header carries one.
function extractApiKey(req) {
  var auth = req.headers.authorization;
  if (typeof auth === 'string') {
    var match = /^Bearer\s+(.*\S)\s*$/i.exec(auth);
    if (match) return match[1];
  }
  var key = req.headers['x-api-key'];
  if (typeof key === 'string' && key.trim()) return key.trim();
  return null;
}

// Express middleware enforcing the configured policy. Register it before any
// static handler or route so that every endpoint is covered.
//   options.apiKey    - required key for non-loopback clients, or falsy for none
//   options.allowList - result of parseAllowList(), or null for any address
function createAccessGate(options) {
  options = options || {};
  var apiKey = options.apiKey || null;
  var allowList = options.allowList || null;

  return function accessGate(req, res, next) {
    // Uses the TCP peer address; X-Forwarded-For is deliberately not trusted.
    var addr = req.socket && req.socket.remoteAddress;
    if (isLoopbackAddress(addr)) return next();

    if (allowList && !allowList.check(addr)) {
      return res.status(403).json({ error: 'forbidden' });
    }
    if (apiKey && !safeEqual(extractApiKey(req), apiKey)) {
      res.set('WWW-Authenticate', 'Bearer');
      return res.status(401).json({ error: 'unauthorized' });
    }
    next();
  };
}

module.exports = {
  normalizeAddress: normalizeAddress,
  isLoopbackAddress: isLoopbackAddress,
  parseAllowList: parseAllowList,
  safeEqual: safeEqual,
  extractApiKey: extractApiKey,
  createAccessGate: createAccessGate
};
