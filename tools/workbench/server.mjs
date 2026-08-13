#!/usr/bin/env node
// PotatoVoxel Workbench: a dependency-free localhost server.  It exchanges
// commands/status with the Gold mod through LOVE's save directory because the
// shipped Lua runtime does not include a socket library.

import http from 'node:http';
import { readFile, mkdir, rename, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname, extname, join, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import { randomUUID } from 'node:crypto';

const here = dirname(fileURLToPath(import.meta.url));
const defaults = {
  modDir: resolve(here, '../..'),
  bridgeDir: join(homedir(), 'Library/Application Support/LOVE/pokemon-love2d/voxel-workbench'),
  port: 8787,
};
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 1) {
  const value = args[i + 1];
  if (args[i] === '--mod-dir' && value) defaults.modDir = resolve(value);
  if (args[i] === '--bridge-dir' && value) defaults.bridgeDir = resolve(value);
  if (args[i] === '--port' && value) defaults.port = Number(value);
}
const publicDir = join(here, 'public');
const overridePath = join(defaults.modDir, 'data/workbench_overrides.json');
const buildingPath = join(defaults.modDir, 'data/workbench_buildings.json');
const cutoutPath = join(defaults.modDir, 'data/workbench_cutouts.json');
const classes = new Set([
  'ground', 'water', 'void', 'ledge', 'fence', 'sign', 'wall', 'tree', 'cliff',
  'roof', 'cylinder', 'canopy', 'stump', 'can', 'planter', 'billboard',
  'signpost', 'post', 'grass', 'flower', 'bed', 'stool', 'counter', 'backrest',
  'table', 'desk', 'prop', 'cutout', 'bike', 'console', 'relief', 'bookcase',
  'stair_e', 'stair_w', 'stair_down_e', 'stair_down_w', 'auto',
]);

async function readJson(path, fallback) {
  try { return JSON.parse(await readFile(path, 'utf8')); }
  catch { return fallback; }
}

async function atomicJson(path, value) {
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
  await rename(temporary, path);
}

function reply(res, status, body, contentType = 'application/json; charset=utf-8') {
  res.writeHead(status, { 'Content-Type': contentType, 'Cache-Control': 'no-store' });
  res.end(typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body));
}

async function requestBody(req) {
  let text = '';
  for await (const chunk of req) {
    text += chunk;
    if (text.length > 64 * 1024) throw new Error('Request body is too large.');
  }
  return text ? JSON.parse(text) : {};
}

function staticPath(pathname) {
  const requested = pathname === '/' ? '/index.html' : pathname;
  const candidate = normalize(join(publicDir, requested));
  return candidate.startsWith(`${publicDir}/`) ? candidate : null;
}

async function status() {
  const value = await readJson(join(defaults.bridgeDir, 'status.json'), null);
  return value || {
    connected: false,
    bridgeDirectory: defaults.bridgeDir,
    message: 'Waiting for Gold to write a workbench status file.',
  };
}

async function command(command) {
  const payload = { ...command, id: randomUUID() };
  await atomicJson(join(defaults.bridgeDir, 'command.json'), payload);
  return payload;
}

function validPin(pin) {
  const tile = Number(pin?.tile);
  return typeof pin?.tilesetId === 'string' && Number.isInteger(tile) && tile >= 0 && tile <= 255
    && classes.has(pin?.class) ? { tilesetId: pin.tilesetId, tile, class: pin.class } : null;
}

async function writePins(pins) {
  const overrides = await readJson(overridePath, { version: 1, tilesets: {} });
  overrides.version = 1;
  overrides.tilesets ||= {};
  for (const pin of pins) {
    overrides.tilesets[pin.tilesetId] ||= { pins: {} };
    overrides.tilesets[pin.tilesetId].pins ||= {};
    overrides.tilesets[pin.tilesetId].pins[String(pin.tile)] = pin.class;
  }
  await atomicJson(overridePath, overrides);
  return overrides;
}

function validBuilding(recipe) {
  const rows = recipe?.tiles;
  if (typeof recipe?.tilesetId !== 'string' || !Array.isArray(rows) || !rows.length || rows.length > 64) return null;
  const width = Array.isArray(rows[0]) ? rows[0].length : 0;
  if (!width || width > 64 || !rows.every((row) => Array.isArray(row) && row.length === width
    && row.every((tile) => Number.isInteger(tile) && tile >= 0 && tile <= 255))) return null;
  const roofRows = Number(recipe.roofRows), roofBack = Number(recipe.roofBack), roofFront = Number(recipe.roofFront), slab = Number(recipe.slab);
  const cycle = recipe.roofCycle;
  if (!Number.isInteger(roofRows) || roofRows < 1 || roofRows > rows.length * 8
    || !Number.isInteger(roofBack) || roofBack < 1 || !Number.isInteger(roofFront) || roofFront < 1
    || !Number.isInteger(slab) || slab < 1 || slab > 16 || !Array.isArray(cycle) || cycle.length !== 2
    || !Number.isInteger(cycle[0]) || !Number.isInteger(cycle[1]) || cycle[0] < 0 || cycle[1] < cycle[0] || cycle[1] >= roofRows) return null;
  return { id: typeof recipe.id === 'string' && /^[a-z0-9_-]{1,80}$/i.test(recipe.id)
      ? recipe.id : `workbench_${Date.now()}`,
    name: typeof recipe.name === 'string' ? recipe.name.slice(0, 80) : 'Captured building',
    tilesetId: recipe.tilesetId, tiles: rows, roofRows, roofBack, roofFront, roofCycle: cycle,
    slab, frontEave: Number.isInteger(recipe.frontEave) ? recipe.frontEave : 0,
    ledge: Array.isArray(recipe.ledge) && recipe.ledge.length === 2 ? recipe.ledge : null };
}

function validCutout(recipe) {
  const tiles = recipe?.tiles, mask = recipe?.mask;
  if (typeof recipe?.tilesetId !== 'string' || !Array.isArray(tiles) || !tiles.length || tiles.length > 48
    || !tiles.every((row) => Array.isArray(row) && row.length === tiles[0]?.length && row.length > 0 && row.length <= 48
      && row.every((tile) => Number.isInteger(tile) && tile >= 0 && tile <= 255))
    || !Array.isArray(mask) || mask.length !== tiles.length * 8
    || !mask.every((row) => typeof row === 'string' && new RegExp(`^[01]{${tiles[0].length * 8}}$`).test(row))) return null;
  const solidPixels = mask.reduce((count, row) => count + [...row].filter((pixel) => pixel === '1').length, 0);
  // Larger connected captures (for example an entire tall tree) are valid.
  // This matches the runtime mesh safety ceiling for one sprite object.
  if (!solidPixels || solidPixels > 4096) return null;
  const depth = Number(recipe.depth);
  if (!Number.isInteger(depth) || depth < 1 || depth > 32) return null;
  return {
    id: typeof recipe.id === 'string' && /^[a-z0-9_-]{1,80}$/i.test(recipe.id)
      ? recipe.id : `cutout_${Date.now()}`,
    name: typeof recipe.name === 'string' ? recipe.name.slice(0, 80) : 'Captured cutout',
    tilesetId: recipe.tilesetId, tiles, mask, depth,
  };
}

const mime = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml' };

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (req.method === 'GET' && url.pathname === '/api/status') return reply(res, 200, await status());
    if (req.method === 'GET' && url.pathname === '/api/overrides') {
      return reply(res, 200, await readJson(overridePath, { version: 1, tilesets: {} }));
    }
    if (req.method === 'GET' && url.pathname === '/api/buildings') {
      return reply(res, 200, await readJson(buildingPath, { version: 1, tilesets: {} }));
    }
    if (req.method === 'GET' && url.pathname === '/api/cutouts') {
      return reply(res, 200, await readJson(cutoutPath, { version: 1, tilesets: {} }));
    }
    if (req.method === 'GET' && url.pathname === '/api/atlas') {
      const atlasPath = join(defaults.bridgeDir, 'live_atlas.png');
      if (!existsSync(atlasPath)) return reply(res, 404, { error: 'Gold has not exported a tileset atlas yet.' });
      return reply(res, 200, await readFile(atlasPath), 'image/png');
    }
    if (req.method === 'POST' && url.pathname === '/api/command') {
      const body = await requestBody(req);
      if (!['teleport', 'reload', 'snapshot', 'capture_building', 'capture_object'].includes(body.op)) {
        return reply(res, 400, { error: 'Command must be teleport, reload, snapshot, capture_building, or capture_object.' });
      }
      if (body.op === 'teleport' && typeof body.mapId !== 'string') {
        return reply(res, 400, { error: 'Teleport requires a map id.' });
      }
      if (['capture_building', 'capture_object'].includes(body.op) && !['x0', 'y0', 'x1', 'y1'].every((key) => Number.isInteger(body[key]))) {
        return reply(res, 400, { error: 'Graphic capture requires integer x0, y0, x1, and y1 cell coordinates.' });
      }
      return reply(res, 202, await command(body));
    }
    if (req.method === 'POST' && url.pathname === '/api/overrides') {
      const body = await requestBody(req);
      const pin = validPin(body);
      if (!pin) {
        return reply(res, 400, { error: 'Expected tilesetId, tile 0–255, and a known shape class.' });
      }
      const overrides = await writePins([pin]);
      return reply(res, 200, { ok: true, overrides });
    }
    if (req.method === 'POST' && url.pathname === '/api/overrides/batch') {
      const body = await requestBody(req);
      const pins = Array.isArray(body.pins) ? body.pins.map(validPin) : [];
      if (!pins.length || pins.length > 512 || pins.some((pin) => !pin)) {
        return reply(res, 400, { error: 'Expected 1–512 valid tile-profile pins.' });
      }
      const overrides = await writePins(pins);
      return reply(res, 200, { ok: true, written: pins.length, overrides });
    }
    if (req.method === 'POST' && url.pathname === '/api/buildings') {
      const recipe = validBuilding(await requestBody(req));
      if (!recipe) return reply(res, 400, { error: 'Invalid building recipe: rectangular tiles plus valid roof settings are required.' });
      const buildings = await readJson(buildingPath, { version: 1, tilesets: {} });
      buildings.version = 1; buildings.tilesets ||= {};
      const recipes = buildings.tilesets[recipe.tilesetId] ||= [];
      const stored = { ...recipe }; delete stored.tilesetId;
      const at = recipes.findIndex((entry) => entry.id === stored.id);
      if (at >= 0) recipes[at] = stored; else recipes.push(stored);
      await atomicJson(buildingPath, buildings);
      return reply(res, 200, { ok: true, recipe: stored, buildings });
    }
    if (req.method === 'POST' && url.pathname === '/api/cutouts') {
      const recipe = validCutout(await requestBody(req));
      if (!recipe) return reply(res, 400, { error: 'A cutout needs a rectangular tile grid up to 48×48 tiles, a matching binary mask, and depth 1–32.' });
      const cutouts = await readJson(cutoutPath, { version: 1, tilesets: {} });
      cutouts.version = 1; cutouts.tilesets ||= {};
      const recipes = cutouts.tilesets[recipe.tilesetId] ||= [];
      const stored = { ...recipe }; delete stored.tilesetId;
      const at = recipes.findIndex((entry) => entry.id === stored.id);
      if (at >= 0) recipes[at] = stored; else recipes.push(stored);
      await atomicJson(cutoutPath, cutouts);
      return reply(res, 200, { ok: true, recipe: stored, cutouts });
    }
    if (req.method === 'GET') {
      const path = staticPath(url.pathname);
      if (!path || !existsSync(path)) return reply(res, 404, 'Not found', 'text/plain; charset=utf-8');
      return reply(res, 200, await readFile(path), mime[extname(path)] || 'application/octet-stream');
    }
    return reply(res, 405, { error: 'Method not allowed.' });
  } catch (error) {
    return reply(res, 500, { error: error instanceof Error ? error.message : String(error) });
  }
});

server.listen(defaults.port, '127.0.0.1', () => {
  console.log(`PotatoVoxel Workbench: http://127.0.0.1:${defaults.port}`);
  console.log(`Bridge directory: ${defaults.bridgeDir}`);
  console.log(`Mod directory: ${defaults.modDir}`);
});
