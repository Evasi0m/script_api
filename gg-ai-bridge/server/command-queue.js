class CommandQueue {
  constructor() {
    this.queue = [];
    this.results = new Map();
    this.maxResults = 200;
  }

  reset() {
    this.queue = [];
    this.results.clear();
  }

  enqueue(command) {
    const item = {
      id: command.id || `cmd_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
      type: command.type,
      target: command.target || null,
      payload: command.payload || {},
      source: command.source || "web",
      createdAt: new Date().toISOString(),
      status: "pending",
    };
    this.queue.push(item);
    return item;
  }

  next() {
    const item = this.queue.find((cmd) => cmd.status === "pending");
    if (!item) return null;
    item.status = "processing";
    item.startedAt = new Date().toISOString();
    return item;
  }

  complete(id, result) {
    const item = this.queue.find((cmd) => cmd.id === id);
    if (!item) return null;
    item.status = result.ok ? "done" : "error";
    item.completedAt = new Date().toISOString();
    const payload = {
      command_id: id,
      type: item.type,
      ok: Boolean(result.ok),
      message: result.message || "",
      data: result.data || null,
      at: new Date().toISOString(),
    };
    this.results.set(id, payload);
    if (this.results.size > this.maxResults) {
      const firstKey = this.results.keys().next().value;
      this.results.delete(firstKey);
    }
    return payload;
  }

  getResult(id) {
    return this.results.get(id) || null;
  }

  pendingCount() {
    return this.queue.filter((cmd) => cmd.status === "pending").length;
  }

  snapshot() {
    return {
      pending: this.pendingCount(),
      recent: this.queue.slice(-20).reverse(),
    };
  }
}

module.exports = { CommandQueue };
