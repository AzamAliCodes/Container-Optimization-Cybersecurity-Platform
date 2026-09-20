<?php
// Sample vulnerable target app (Phase 0 baseline). Deliberately naive: SQL injection in
// the "id" parameter. Kept dependency-free (no framework) so the legacy image's bloat
// comes purely from the baked single-stage toolchain, not app code.
$id = $_GET['id'] ?? '1';
try {
    $pdo = new PDO('sqlite:' . __DIR__ . '/data/app.db');
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
} catch (PDOException $e) {
    $pdo = null;
}
if ($pdo === null) {
    http_response_code(500);
    echo "db unavailable";
    exit;
}
// SQLi sink: string concatenation directly into query.
$sql = "SELECT id, name, password FROM users WHERE id = " . $id;
$rows = [];
try {
    foreach ($pdo->query($sql) as $row) {
        $rows[] = $row;
    }
} catch (PDOException $e) {
    http_response_code(500);
    echo "query error: " . $e->getMessage();
    exit;
}
header('Content-Type: text/plain');
foreach ($rows as $r) {
    echo "{$r['id']}|{$r['name']}|{$r['password']}\n";
}
