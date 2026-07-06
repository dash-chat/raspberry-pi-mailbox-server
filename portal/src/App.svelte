<script lang="ts">
  interface Health {
    status: string
    endpoint_id: string
  }

  // nginx proxies /api/ -> the local mailbox server, so this is same-origin
  // and works inside captive-portal webviews (no CORS involved).
  async function fetchHealth(): Promise<Health> {
    const res = await fetch('/api/health')
    if (!res.ok) throw new Error(`mailbox responded ${res.status}`)
    return res.json()
  }

  let health = $state<Promise<Health>>(fetchHealth())

  function refresh() {
    health = fetchHealth()
  }
</script>

<main>
  <div class="logo" aria-hidden="true">⬡</div>
  <h1>Welcome to the Dash&nbsp;Chat mesh</h1>
  <p class="lead">
    You're connected to a local, off-grid network. Messages you send with the
    Dash&nbsp;Chat app are stored on this mailbox and delivered to anyone else
    on the mesh — no internet needed.
  </p>

  <section class="status">
    {#await health}
      <span class="dot pending"></span> Checking mailbox…
    {:then h}
      <span class="dot ok"></span> Mailbox online
      <code class="endpoint" title="MailboxId">{h.endpoint_id}</code>
    {:catch}
      <span class="dot bad"></span> Mailbox unreachable
      <button onclick={refresh}>Retry</button>
    {/await}
  </section>

  <section class="steps">
    <h2>Get started</h2>
    <ol>
      <li>Install the <strong>Dash Chat</strong> app on your phone.</li>
      <li>Stay connected to this Wi-Fi network.</li>
      <li>
        Open the app — it discovers this mailbox automatically and syncs your
        conversations with everyone on the mesh.
      </li>
    </ol>
  </section>

  <p class="note">
    This network may not provide internet access. You can safely dismiss the
    sign-in screen and keep using the mesh.
  </p>
</main>

<style>
  main {
    max-width: 34rem;
    width: 100%;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 1rem;
    padding: 2rem;
    backdrop-filter: blur(8px);
  }

  .logo {
    font-size: 3rem;
    line-height: 1;
    color: #7aa2ff;
  }

  h1 {
    margin: 0.5rem 0 0;
    font-size: 1.6rem;
  }

  .lead {
    color: #aeb8cc;
    line-height: 1.5;
  }

  .status {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    flex-wrap: wrap;
    padding: 0.75rem 1rem;
    border-radius: 0.6rem;
    background: rgba(0, 0, 0, 0.25);
    font-size: 0.95rem;
  }

  .dot {
    width: 0.6rem;
    height: 0.6rem;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .dot.ok {
    background: #4ade80;
    box-shadow: 0 0 8px #4ade80;
  }

  .dot.bad {
    background: #f87171;
  }

  .dot.pending {
    background: #facc15;
  }

  .endpoint {
    font-size: 0.75rem;
    color: #8fa3c8;
    overflow-wrap: anywhere;
  }

  button {
    margin-left: auto;
    background: #2c3e5f;
    color: inherit;
    border: 1px solid rgba(255, 255, 255, 0.15);
    border-radius: 0.4rem;
    padding: 0.25rem 0.75rem;
    cursor: pointer;
  }

  .steps h2 {
    font-size: 1.05rem;
    margin-bottom: 0.25rem;
  }

  .steps ol {
    margin: 0;
    padding-left: 1.25rem;
    color: #c6cede;
    line-height: 1.6;
  }

  .note {
    margin-bottom: 0;
    font-size: 0.85rem;
    color: #8b94a8;
  }
</style>
