async function checkServer() {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 3000);
  try {
    const res = await fetch('http://localhost:3456/health', { signal: controller.signal });
    clearTimeout(timer);
    if (res.ok) {
      document.getElementById('dot').classList.add('connected');
      document.getElementById('statusText').textContent = 'Servidor conectado';
    } else {
      document.getElementById('statusText').textContent = 'Error del servidor';
    }
  } catch (e) {
    clearTimeout(timer);
    document.getElementById('statusText').textContent = 'Servidor desconectado';
  }
}
checkServer();
