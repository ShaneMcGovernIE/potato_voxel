const $ = (id) => document.getElementById(id);
const classes = ['auto','ground','water','void','ledge','fence','sign','wall','tree','cliff','roof','cylinder','canopy','stump','can','planter','billboard','signpost','post','grass','flower','bed','stool','counter','backrest','table','desk','prop','cutout','bike','console','relief','bookcase','stair_e','stair_w','stair_down_e','stair_down_w'];
const heights = { ground:0, water:-2, void:0, ledge:6, fence:10, sign:12, wall:16, tree:16, cliff:32, roof:28, cylinder:16, canopy:32, stump:16, can:9, planter:32, billboard:16, signpost:16, post:16, grass:0, flower:0, bed:7, stool:8, counter:8, backrest:12, table:12, desk:24, prop:16, cutout:16, bike:16, console:16, relief:3, bookcase:32, stair_e:16, stair_w:16, stair_down_e:16, stair_down_w:16 };
const colors = { ground:'#6dbb55', water:'#557ee8', ledge:'#a59a70', fence:'#8f704b', sign:'#c2a66b', wall:'#8d95a3', tree:'#3e8549', cliff:'#796c60', roof:'#a55a58', cylinder:'#3e8549', canopy:'#2f7542', stump:'#7b593d', can:'#80929a', planter:'#9d5e48', billboard:'#d1a767', signpost:'#bd985d', post:'#8f704b', grass:'#4fa34e', flower:'#df6a98', bed:'#b76a72', stool:'#7b593d', counter:'#a47b5b', backrest:'#b68171', table:'#a47b5b', desk:'#835c42', prop:'#a69279', cutout:'#d0b570', bike:'#e1694e', console:'#718bb0', relief:'#9c9d8b', bookcase:'#875f3f', stair_e:'#9f8f79', stair_w:'#9f8f79', stair_down_e:'#716a65', stair_down_w:'#716a65' };
let state = null, selectedCellKey = null, selectedTileKey = null, mapRows = [];
let northWest = null, southEast = null, atlasRevision = null, atlasImage = null;
let captureFingerprint = null, recipeMessage = '';
let objectNorthWest = null, objectSouthEast = null, cutoutMask = null, cutoutMessage = '', cutoutView = null, objectCaptureFingerprint = null, objectCaptureSource = null;
let cutoutPainting = null, cutoutPaintedPixels = new Set();

$('shape').innerHTML = classes.map((value) => `<option value="${value}">${value}</option>`).join('');
async function api(path, options) { const response = await fetch(path, options); const body = await response.json(); if (!response.ok) throw new Error(body.error || 'Request failed'); return body; }
function currentMap() { return state?.map; }
function cellKey(cell) { return `${cell.x},${cell.y}`; }
function tileKey(tile) { return `${tile.x},${tile.y}`; }
function cells() { return state?.nearbyCells || []; }
function selectedCell() { return cells().find((cell) => cellKey(cell) === selectedCellKey) || null; }
function selectedTile() { return selectedCell()?.tiles.find((tile) => tileKey(tile) === selectedTileKey) || null; }
function captured() { return state?.lastCapture || null; }
function captureBounds() {
  if (!(northWest && southEast)) return null;
  return { x0:Math.min(northWest.x, southEast.x), y0:Math.min(northWest.y, southEast.y), x1:Math.max(northWest.x, southEast.x), y1:Math.max(northWest.y, southEast.y) };
}
function objectBounds() {
  if (!(objectNorthWest && objectSouthEast)) return null;
  return { x0:Math.min(objectNorthWest.x, objectSouthEast.x), y0:Math.min(objectNorthWest.y, objectSouthEast.y), x1:Math.max(objectNorthWest.x, objectSouthEast.x), y1:Math.max(objectNorthWest.y, objectSouthEast.y) };
}
function objectCapture() { return objectCaptureSource === 'building' ? state?.lastCapture || null : null; }
function mapOptions() {
  const filter = $('map-filter').value.trim().toLowerCase(), selected = $('map').value;
  const rows = mapRows.filter((row) => !filter || `${row.id} ${row.name}`.toLowerCase().includes(filter));
  $('map').innerHTML = rows.map((row) => `<option value="${row.id}">${row.name} · ${row.id}</option>`).join('');
  if (rows.some((row) => row.id === selected)) $('map').value = selected;
  else if (currentMap()) $('map').value = currentMap().id;
}
function choose(cell, tile) { selectedCellKey = cell ? cellKey(cell) : null; selectedTileKey = tile ? tileKey(tile) : null; render(); }
function stampPins(pins) { return api('/api/overrides/batch', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({ pins }) }); }
function pinFor(tile, className) { return { tilesetId: currentMap()?.tilesetId, tile: tile.id, class: className }; }
function tileCanvas(cell) {
  const ids = cell.tiles.map((tile) => tile.id).join(',');
  return `<canvas class="cell-art" width="16" height="16" data-tiles="${ids}" aria-label="Game tiles ${ids}"></canvas>`;
}
function paintTileCanvases() {
  if (!(atlasImage?.complete && atlasImage.naturalWidth)) return;
  const perRow = currentMap()?.tilesPerRow || 16;
  document.querySelectorAll('.cell-art').forEach((canvas) => {
    const ids = canvas.dataset.tiles.split(',').map(Number), context = canvas.getContext('2d');
    context.clearRect(0, 0, 16, 16);
    ids.forEach((tile, index) => {
      const dx = (index % 2) * 8, dy = Math.floor(index / 2) * 8;
      context.drawImage(atlasImage, (tile % perRow) * 8, Math.floor(tile / perRow) * 8, 8, 8, dx, dy, 8, 8);
    });
  });
}
function refreshAtlas() {
  const revision = state?.atlas?.revision;
  if (!revision || revision === atlasRevision) return;
  atlasRevision = revision; atlasImage = new Image();
  atlasImage.onload = () => { paintTileCanvases(); drawPreview(); drawCutout(); };
  atlasImage.src = `/api/atlas?revision=${encodeURIComponent(revision)}`;
}
function capturePixels(capture) {
  if (!(capture?.tiles?.length && atlasImage?.complete && atlasImage.naturalWidth)) return null;
  const width = capture.tiles[0].length * 8, height = capture.tiles.length * 8;
  const source = document.createElement('canvas'); source.width = width; source.height = height;
  const context = source.getContext('2d'), perRow = currentMap()?.tilesPerRow || 16;
  capture.tiles.forEach((row, y) => row.forEach((tile, x) => context.drawImage(atlasImage,
    (tile % perRow) * 8, Math.floor(tile / perRow) * 8, 8, 8, x * 8, y * 8, 8, 8)));
  return context.getImageData(0, 0, width, height);
}
function automaticCutoutMask(capture) {
  const image = capturePixels(capture); if (!image) return null;
  const width = image.width, height = image.height, open = Array(width * height).fill(false), seen = Array(width * height).fill(false), queue = [];
  for (let y = 0; y < height; y += 1) for (let x = 0; x < width; x += 1) {
    const i = y * width + x, p = i * 4, dark = image.data[p + 3] === 0 || Math.min(image.data[p], image.data[p + 1], image.data[p + 2]) <= 64;
    open[i] = !dark;
    if (open[i] && (x === 0 || y === 0 || x === width - 1 || y === height - 1)) { seen[i] = true; queue.push(i); }
  }
  while (queue.length) {
    const i = queue.pop(), x = i % width, y = Math.floor(i / width);
    for (const [dx, dy] of [[1,0],[-1,0],[0,1],[0,-1]]) {
      const nx = x + dx, ny = y + dy, ni = ny * width + nx;
      if (nx >= 0 && nx < width && ny >= 0 && ny < height && open[ni] && !seen[ni]) { seen[ni] = true; queue.push(ni); }
    }
  }
  return Array.from({ length:height }, (_, y) => Array.from({ length:width }, (_, x) => seen[y * width + x] ? '0' : '1').join(''));
}
function drawCutout() {
  const canvas = $('cutout-preview'), context = canvas.getContext('2d'), capture = objectCapture();
  context.clearRect(0, 0, canvas.width, canvas.height); context.fillStyle = '#101827'; context.fillRect(0, 0, canvas.width, canvas.height); cutoutView = null;
  const image = capturePixels(capture);
  if (!image) { context.fillStyle = '#9dabc2'; context.font = '14px system-ui'; context.fillText('Capture an object; its editable artwork appears here.', 14, canvas.height / 2); return; }
  const width = image.width, height = image.height, scale = Math.max(1, Math.floor(Math.min(canvas.width / width, canvas.height / height)));
  const x0 = Math.floor((canvas.width - width * scale) / 2), y0 = Math.floor((canvas.height - height * scale) / 2);
  const source = document.createElement('canvas'); source.width = width; source.height = height; source.getContext('2d').putImageData(image, 0, 0);
  context.imageSmoothingEnabled = false; context.drawImage(source, 0, 0, width, height, x0, y0, width * scale, height * scale); cutoutView = { x0, y0, scale, width, height };
  if (cutoutMask) for (let y = 0; y < height; y += 1) for (let x = 0; x < width; x += 1) {
    if (cutoutMask[y]?.[x] === '0') { context.fillStyle = 'rgba(224, 64, 74, .58)'; context.fillRect(x0 + x * scale, y0 + y * scale, scale, scale); }
    if (scale >= 8) { context.strokeStyle = 'rgba(8,14,24,.30)'; context.strokeRect(x0 + x * scale + .5, y0 + y * scale + .5, scale - 1, scale - 1); }
  }
}
function renderCutout() {
  const capture = objectCapture(), ready = capture?.tiles?.length && cutoutMask;
  $('save-cutout').disabled = !ready;
  if (!ready && !cutoutMessage) $('cutout-status').textContent = 'Capture an object, then build its editable pixel mask.';
  else if (ready && !cutoutMessage) $('cutout-status').textContent = `Click any pixel to toggle it. Red pixels are cut away; visible pixels become a ${number('cutout-depth')}-voxel-deep 3D prism.`;
  else $('cutout-status').textContent = cutoutMessage;
  drawCutout();
}
function renderObjectCapture() {
  const bounds = objectBounds(), capture = objectCapture();
  const fingerprint = captureKey(capture);
  if (fingerprint && fingerprint !== objectCaptureFingerprint) {
    objectCaptureFingerprint = fingerprint;
    cutoutMask = null;
    cutoutMessage = 'Object tiles captured. Build an editable pixel mask from this exact artwork.';
  }
  $('object-capture-status').textContent = bounds ? `Corners: ${bounds.x0},${bounds.y0} → ${bounds.x1},${bounds.y1}. Capture the exact object artwork from Gold.` : 'Select the object’s top-left and bottom-right cells. Include the complete tree/sign, but not its surrounding ground.';
  if (capture?.tiles?.length) $('object-capture-status').textContent += ` Captured ${capture.tiles[0].length}×${capture.tiles.length} graphic tiles.`;
}
function setRecommendedSettings(capture = captured()) {
  const artHeight = (capture?.tiles?.length || 2) * 8, roofRows = Math.min(16, artHeight);
  $('roof-rows').value = roofRows;
  $('roof-back').value = roofRows >= 16 ? 7 : Math.max(1, Math.floor(roofRows / 2));
  $('roof-front').value = roofRows >= 16 ? 9 : Math.max(1, Math.ceil(roofRows / 2));
  $('roof-cycle-start').value = Math.min(5, roofRows - 1);
  $('roof-cycle-end').value = Math.min(8, roofRows - 1);
  $('slab').value = 4; $('front-eave').value = 4;
}
function captureKey(capture) {
  return capture && [capture.mapId, capture.x0, capture.y0, capture.x1, capture.y1,
    ...(capture.tiles || []).flat()].join(':');
}
function recipeIssue(capture = captured()) {
  if (!capture?.tiles?.length) return 'Capture the house first.';
  const artHeight = capture.tiles.length * 8, roofRows = number('roof-rows'), cycleStart = number('roof-cycle-start'), cycleEnd = number('roof-cycle-end');
  if (!Number.isInteger(roofRows) || roofRows < 1 || roofRows > artHeight) return `Roof art rows must be an integer from 1 to ${artHeight}.`;
  if (!Number.isInteger(cycleStart) || !Number.isInteger(cycleEnd) || cycleStart < 0 || cycleEnd < cycleStart || cycleEnd >= roofRows) return `Roof repeat must be inside the roof band: 0–${roofRows - 1}.`;
  for (const [id, label, low, high] of [['roof-back', 'Roof back depth', 1, 32], ['roof-front', 'Roof front depth', 1, 32], ['slab', 'Wall slab depth', 1, 16], ['front-eave', 'Front eave', 0, 16]]) {
    const value = number(id); if (!Number.isInteger(value) || value < low || value > high) return `${label} must be an integer from ${low} to ${high}.`;
  }
  return null;
}
function drawPreview() {
  const canvas = $('voxel-preview'), context = canvas.getContext('2d'), capture = captured();
  context.clearRect(0, 0, canvas.width, canvas.height); context.fillStyle = '#101827'; context.fillRect(0, 0, canvas.width, canvas.height);
  if (!capture?.tiles?.length) { context.fillStyle = '#9dabc2'; context.font = '14px system-ui'; context.fillText('Capture a whole house to inspect its real artwork.', 18, 110); return; }
  const cols = capture.tiles[0].length, rows = capture.tiles.length, artW = cols * 8, artH = rows * 8;
  const scale = Math.max(1, Math.floor(Math.min((canvas.width - 24) / artW, (canvas.height - 50) / artH)));
  const x0 = Math.floor((canvas.width - artW * scale) / 2), y0 = 30;
  context.imageSmoothingEnabled = false;
  if (atlasImage?.complete && atlasImage.naturalWidth) {
    const perRow = currentMap()?.tilesPerRow || 16;
    capture.tiles.forEach((row, y) => row.forEach((tile, x) => context.drawImage(atlasImage,
      (tile % perRow) * 8, Math.floor(tile / perRow) * 8, 8, 8,
      x0 + x * 8 * scale, y0 + y * 8 * scale, 8 * scale, 8 * scale)));
  } else {
    context.fillStyle = '#293750'; context.fillRect(x0, y0, artW * scale, artH * scale);
    context.fillStyle = '#d8e5fa'; context.font = '12px system-ui'; context.fillText('Loading Gold tile artwork…', 12, 20); return;
  }
  const roofRows = number('roof-rows'), guideY = y0 + roofRows * scale;
  context.fillStyle = 'rgba(255, 185, 72, .18)'; context.fillRect(x0, y0, artW * scale, Math.max(0, Math.min(artH * scale, roofRows * scale)));
  context.strokeStyle = '#ffba48'; context.lineWidth = 2; context.beginPath(); context.moveTo(x0, guideY); context.lineTo(x0 + artW * scale, guideY); context.stroke();
  context.fillStyle = '#d8e5fa'; context.font = '12px system-ui'; context.fillText('Captured house art — orange line: roof → façade fold', 12, 18);
}
function renderCapture() {
  const bounds = captureBounds(), capture = captured();
  $('capture-status').textContent = bounds
    ? `Corners: ${bounds.x0},${bounds.y0} → ${bounds.x1},${bounds.y1}. Press “Capture house tiles” to read the exact artwork from Gold.`
    : 'Select the top-left and bottom-right cells of one house, including its roof and porch, then capture.';
  if (!capture?.tiles?.length) { $('capture-grid').textContent = 'Capture a house to see its exact 8×8 tile layout.'; renderRecipeStatus(); return; }
  const fingerprint = captureKey(capture);
  if (fingerprint !== captureFingerprint) { captureFingerprint = fingerprint; setRecommendedSettings(capture); recipeMessage = 'Recommended Johto-home geometry was applied. Save, then hot reload.'; }
  const rows = capture.tiles.map((row) => row.map((tile) => String(tile).padStart(3, ' ')).join(' '));
  $('capture-grid').textContent = `${capture.mapId} · ${capture.tilesetId}\n${capture.x0},${capture.y0} → ${capture.x1},${capture.y1} (${capture.tiles[0].length}×${capture.tiles.length} graphic tiles)\n\n${rows.join('\n')}`;
  renderRecipeStatus();
}
function renderRecipeStatus() {
  const issue = recipeIssue(), save = $('save-building');
  save.disabled = !!issue;
  $('recipe-status').classList.toggle('error', !!issue);
  $('recipe-status').textContent = issue || recipeMessage || 'Geometry is valid. Save this recipe, then hot reload Gold.';
}
function render() {
  const map = currentMap(), player = state?.player, cell = selectedCell(), tile = selectedTile(), bounds = captureBounds(), object = objectBounds();
  $('connection').textContent = state?.connected ? 'Connected to Gold' : 'Waiting for game'; $('connection').classList.toggle('connected', !!state?.connected);
  $('game-status').textContent = state?.lastError || state?.message || `Bridge: ${state?.bridgeDirectory || '—'}`;
  $('location').textContent = map && player ? `${map.name} (${map.id}) · ${map.tilesetId} · player ${player.x}, ${player.y} facing ${player.facing}` : 'No overworld data yet.';
  const near = $('nearby'); near.innerHTML = cells().map((entry) => {
    const selected = cellKey(entry) === selectedCellKey, inBounds = bounds && entry.x >= bounds.x0 && entry.x <= bounds.x1 && entry.y >= bounds.y0 && entry.y <= bounds.y1;
    const inObject = object && entry.x >= object.x0 && entry.x <= object.x1 && entry.y >= object.y0 && entry.y <= object.y1;
    return `<button class="cell ${player && entry.x === player.x && entry.y === player.y ? 'player' : ''} ${selected ? 'active' : ''} ${inBounds ? 'capture' : ''} ${inObject ? 'object-capture' : ''}" data-cell="${cellKey(entry)}">${tileCanvas(entry)}<span>${entry.x},${entry.y}</span><small>${entry.walkable ? 'walk' : entry.water ? 'water' : 'block'}</small></button>`;
  }).join('');
  near.querySelectorAll('[data-cell]').forEach((button) => button.onclick = () => choose(cells().find((entry) => cellKey(entry) === button.dataset.cell)));
  $('objects').textContent = state?.nearbyObjects?.length ? `Nearby objects: ${state.nearbyObjects.map((object) => `${object.name || 'NPC'} @ ${object.x},${object.y}`).join(' · ')}` : '';
  if (!cell) { $('selection').textContent = 'Click a nearby cell, then one of its four graphic tiles.'; $('tile-detail').textContent = ''; }
  else {
    $('selection').innerHTML = `Cell <b>${cell.x}, ${cell.y}</b> · collision ${cell.collision}`;
    $('tile-detail').innerHTML = `<div class="tiles">${cell.tiles.map((entry) => `<button class="tile ${tileKey(entry) === selectedTileKey ? 'active' : ''}" data-tile="${tileKey(entry)}">tile ${entry.id}<br>${entry.class} · h${entry.height ?? heights[entry.class] ?? '?' }${entry.authored ? ' · pinned' : ''}</button>`).join('')}</div>`;
    $('tile-detail').querySelectorAll('[data-tile]').forEach((button) => button.onclick = () => { const chosen = cell.tiles.find((entry) => tileKey(entry) === button.dataset.tile); choose(cell, chosen); $('shape').value = chosen.class; });
    if (tile && classes.includes(tile.class)) $('shape').value = tile.class;
  }
  renderCapture(); renderObjectCapture(); renderCutout(); drawPreview(); paintTileCanvases();
}
async function refresh() {
  try { state = await api('/api/status'); mapRows = state.maps || mapRows; mapOptions(); refreshAtlas(); render(); }
  catch (error) { $('game-status').textContent = error.message; }
}
async function send(op, extra = {}) { await api('/api/command', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({op,...extra}) }); setTimeout(refresh, 350); }
function number(id) { return Number($(id).value); }
function recipeId(name) { return `workbench_${name.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '').slice(0, 54) || 'house'}`; }

$('map-filter').oninput = mapOptions;
$('teleport').onclick = () => send('teleport', { mapId:$('map').value, x:number('x'), y:number('y'), facing:$('facing').value });
$('reload').onclick = () => send('reload');
$('reload-building').onclick = () => send('reload');
$('save-pin').onclick = async () => { const tile = selectedTile(); if (!tile || !currentMap()) return; await api('/api/overrides', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(pinFor(tile, $('shape').value)) }); $('game-status').textContent = 'Tile override written. Press Hot reload profile to apply it in Gold.'; };
$('save-cell').onclick = async () => { const cell = selectedCell(); if (!cell || !currentMap()) return; const result = await stampPins(cell.tiles.map((tile) => pinFor(tile, $('shape').value))); $('game-status').textContent = `${result.written} cell pins written. Press Hot reload profile to apply them.`; };
async function captureObject(bounds) {
  objectCaptureSource = 'building';
  objectCaptureFingerprint = captureKey(state?.lastCapture);
  await send('capture_building', bounds);
  cutoutMask = null;
  cutoutMessage = 'Gold is reading the selected object tiles…';
  renderCutout();
}
$('capture-selected-object').onclick = async () => {
  const cell = selectedCell();
  if (!cell) { $('object-capture-status').textContent = 'Click the sign/prop cell you want to edit first.'; return; }
  objectNorthWest = { x:cell.x, y:cell.y };
  objectSouthEast = { x:cell.x, y:cell.y };
  render();
  await captureObject(objectBounds());
};
$('set-object-nw').onclick = () => { const cell = selectedCell(); if (!cell) return; objectNorthWest = { x:cell.x, y:cell.y }; render(); };
$('set-object-se').onclick = () => { const cell = selectedCell(); if (!cell) return; objectSouthEast = { x:cell.x, y:cell.y }; render(); };
$('capture-object').onclick = async () => {
  const bounds = objectBounds();
  if (!bounds) { $('object-capture-status').textContent = 'Set both object corners first.'; return; }
  await captureObject(bounds);
};
$('make-cutout').onclick = () => {
  const capture = objectCapture(), mask = automaticCutoutMask(capture);
  if (!capture?.tiles?.length) { cutoutMessage = 'Capture the object tiles first.'; renderCutout(); return; }
  if (!mask) { cutoutMessage = 'Gold tile artwork is still loading; try again in a moment.'; renderCutout(); return; }
  cutoutMask = mask; cutoutMessage = 'Automatic black-outline cut applied. Click red/visible pixels to correct it.'; renderCutout();
};
$('invert-cutout').onclick = () => { if (!cutoutMask) return; cutoutMask = cutoutMask.map((row) => [...row].map((pixel) => pixel === '1' ? '0' : '1').join('')); cutoutMessage = 'Mask inverted.'; renderCutout(); };
function cutoutPixelAt(event) {
  if (!(cutoutMask && cutoutView)) return;
  const rect = event.currentTarget.getBoundingClientRect();
  const px = (event.clientX - rect.left) * event.currentTarget.width / rect.width, py = (event.clientY - rect.top) * event.currentTarget.height / rect.height;
  const x = Math.floor((px - cutoutView.x0) / cutoutView.scale), y = Math.floor((py - cutoutView.y0) / cutoutView.scale);
  return x < 0 || y < 0 || x >= cutoutView.width || y >= cutoutView.height ? null : { x, y };
}
function paintCutoutPixel(pixel) {
  if (!pixel || cutoutPainting === null) return;
  const key = `${pixel.x},${pixel.y}`;
  if (cutoutPaintedPixels.has(key)) return;
  cutoutPaintedPixels.add(key);
  const row = cutoutMask[pixel.y];
  cutoutMask[pixel.y] = row.slice(0, pixel.x) + cutoutPainting + row.slice(pixel.x + 1);
  cutoutMessage = 'Mask edited. Drag to paint more pixels, then save when the silhouette is right.';
  renderCutout();
}
$('cutout-preview').onpointerdown = (event) => {
  const pixel = cutoutPixelAt(event);
  if (!pixel) return;
  cutoutPainting = cutoutMask[pixel.y][pixel.x] === '1' ? '0' : '1';
  cutoutPaintedPixels = new Set();
  event.currentTarget.setPointerCapture(event.pointerId);
  paintCutoutPixel(pixel);
};
$('cutout-preview').onpointermove = (event) => {
  if (cutoutPainting !== null) paintCutoutPixel(cutoutPixelAt(event));
};
function stopCutoutPainting(event) {
  if (event.currentTarget.hasPointerCapture?.(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId);
  cutoutPainting = null;
  cutoutPaintedPixels.clear();
}
$('cutout-preview').onpointerup = stopCutoutPainting;
$('cutout-preview').onpointercancel = stopCutoutPainting;
$('save-cutout').onclick = async () => {
  const capture = objectCapture(); if (!(capture?.tiles?.length && cutoutMask && currentMap())) return;
  const name = $('cutout-name').value.trim() || 'Captured cutout', depth = number('cutout-depth');
  const recipe = { id:`cutout_${name.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '').slice(0, 62) || 'object'}`, name, tilesetId:capture.tilesetId,
    tiles:capture.tiles, mask:cutoutMask, depth };
  try { const result = await api('/api/cutouts', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(recipe) }); cutoutMessage = `Saved “${result.recipe.name}”. Hot reload Gold to voxelize this exact tile pattern.`; }
  catch (error) { cutoutMessage = `Save failed: ${error.message}`; }
  renderCutout();
};
$('reload-cutout').onclick = () => send('reload');
$('set-nw').onclick = () => { const cell = selectedCell(); if (!cell) return; northWest = { x:cell.x, y:cell.y }; render(); };
$('set-se').onclick = () => { const cell = selectedCell(); if (!cell) return; southEast = { x:cell.x, y:cell.y }; render(); };
$('capture-building').onclick = async () => { const bounds = captureBounds(); if (!bounds) { $('capture-status').textContent = 'Set both capture corners first.'; return; } await send('capture_building', bounds); $('capture-status').textContent = 'Gold is reading the selected house tiles…'; };
$('reset-building').onclick = () => { setRecommendedSettings(); recipeMessage = 'Recommended Johto-home geometry restored.'; renderRecipeStatus(); drawPreview(); };
$('save-building').onclick = async () => {
  const capture = captured(), issue = recipeIssue();
  if (issue) { recipeMessage = ''; renderRecipeStatus(); return; }
  const name = $('building-name').value.trim() || 'Captured house';
  const recipe = { id:recipeId(name), name, tilesetId:capture.tilesetId, tiles:capture.tiles, roofRows:number('roof-rows'), roofBack:number('roof-back'), roofFront:number('roof-front'), roofCycle:[number('roof-cycle-start'), number('roof-cycle-end')], slab:number('slab'), frontEave:number('front-eave') };
  try {
    const result = await api('/api/buildings', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(recipe) });
    recipeMessage = `Saved “${result.recipe.name}” for ${capture.tilesetId}. Now hot reload Gold.`;
  } catch (error) { recipeMessage = `Save failed: ${error.message}`; }
  renderRecipeStatus();
};
['roof-rows','roof-back','roof-front','roof-cycle-start','roof-cycle-end','slab','front-eave'].forEach((id) => $(id).oninput = () => { recipeMessage = ''; renderRecipeStatus(); drawPreview(); });
document.querySelectorAll('[data-move]').forEach((button) => button.onclick = () => { const cell = selectedCell(); if (!cell) return; const delta = {up:[0,-1],down:[0,1],left:[-1,0],right:[1,0]}[button.dataset.move]; choose(cells().find((entry) => entry.x === cell.x + delta[0] && entry.y === cell.y + delta[1])); });
setInterval(refresh, 700); refresh();
