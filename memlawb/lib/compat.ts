for (const suffix of [
  "URL", "API_KEY", "PASSPHRASE", "NAMESPACE", "SCAN", "HOME", "DATA_DIR",
  "SUPABASE_URL", "SUPABASE_SECRET_KEY",
]) {
  const value = process.env[`MEMLAWB_${suffix}`];
  if (value !== undefined) process.env[`OPENRECALL_${suffix}`] = value;
}

process.env.OPENRECALL_URL ||= "http://localhost:8080";
process.env.OPENRECALL_HOME ||= `${process.env.HOME}/.memlawb`;

await import("./bin/openrecall.ts");
