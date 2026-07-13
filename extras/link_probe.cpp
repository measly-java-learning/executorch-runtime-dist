// Minimal link probe: exists only so the nm-guard can assert the extras'
// registrar TUs survive a real whole-archive link. Never run; linking is enough.
int main() { return 0; }
