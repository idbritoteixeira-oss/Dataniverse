import 'dart:convert';

import 'package:flutter/material.dart';

import '../database/enx_db.dart';

/// Tela de edição visual da base de dados.
/// Permite navegar tabelas, listar/editar/adicionar/eliminar registros
/// e eliminar tabelas inteiras.
class DbEditorPage extends StatefulWidget {
  const DbEditorPage({super.key, required this.database});

  final EnXDB database;

  @override
  State<DbEditorPage> createState() => _DbEditorPageState();
}

class _DbEditorPageState extends State<DbEditorPage> {
  List<String> _tables = [];
  String? _selectedTable;
  List<Map<String, dynamic>> _records = [];
  bool _loadingTables = true;
  bool _loadingRecords = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadTables();
  }

  Future<void> _loadTables() async {
    setState(() {
      _loadingTables = true;
      _error = null;
    });
    try {
      final tables = await widget.database.listTables();
      setState(() {
        _tables = tables;
        _loadingTables = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loadingTables = false;
      });
    }
  }

  Future<void> _selectTable(String table) async {
    setState(() {
      _selectedTable = table;
      _loadingRecords = true;
      _records = [];
      _error = null;
    });
    try {
      final records = await widget.database.listRecords(table);
      setState(() {
        _records = records;
        _loadingRecords = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loadingRecords = false;
      });
    }
  }

  Future<void> _refreshRecords() async {
    if (_selectedTable == null) return;
    await _selectTable(_selectedTable!);
  }

  Future<void> _deleteTable(String table) async {
    final confirm = await _confirmDialog(
      'Eliminar tabela "$table"?',
      'Todos os registros e índices serão removidos permanentemente.',
    );
    if (!confirm) return;

    try {
      await widget.database.deleteTable(table);
      setState(() {
        _tables.remove(table);
        if (_selectedTable == table) {
          _selectedTable = null;
          _records = [];
        }
      });
      _showMessage('Tabela "$table" eliminada.');
    } catch (e) {
      _showMessage('Erro: $e');
    }
  }

  Future<void> _deleteRecord(Map<String, dynamic> record) async {
    final id = record['id']?.toString() ?? '';
    final confirm = await _confirmDialog(
      'Eliminar registro?',
      'ID: $id\nEssa ação não pode ser desfeita.',
    );
    if (!confirm) return;

    try {
      await widget.database.deleteRecord(_selectedTable!, id);
      await _refreshRecords();
      _showMessage('Registro eliminado.');
    } catch (e) {
      _showMessage('Erro: $e');
    }
  }

  Future<void> _openRecordEditor({Map<String, dynamic>? existing}) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _RecordEditorPage(
          database: widget.database,
          table: _selectedTable!,
          existing: existing,
        ),
      ),
    );
    if (result == true) await _refreshRecords();
  }

  Future<bool> _confirmDialog(String title, String body) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: Text(body),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Confirmar'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _showMessage(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Editor da Base de Dados',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: 'Recarregar tabelas',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadTables,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loadingTables
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _tables.isEmpty
              ? Center(
                  child: Text(
                    _error!,
                    style: TextStyle(color: colorScheme.error),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 700;
                    if (wide) {
                      return Row(
                        children: [
                          SizedBox(
                            width: 260,
                            child: _buildTableList(),
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(child: _buildRecordPanel()),
                        ],
                      );
                    }
                    return _selectedTable == null
                        ? _buildTableList()
                        : _buildRecordPanel();
                  },
                ),
    );
  }

  Widget _buildTableList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Tabelas (${_tables.length})',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
        if (_tables.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Nenhuma tabela ainda.\nInsira dados via TCP para criar.',
              style: TextStyle(color: Color(0xFF9AA7BD)),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: _tables.length,
              itemBuilder: (context, i) {
                final table = _tables[i];
                final selected = _selectedTable == table;
                return ListTile(
                  selected: selected,
                  selectedTileColor: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.1),
                  leading: Icon(
                    Icons.table_rows_outlined,
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  title: Text(
                    table,
                    style: TextStyle(
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.normal,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    color: Theme.of(context).colorScheme.error,
                    tooltip: 'Eliminar tabela',
                    onPressed: () => _deleteTable(table),
                  ),
                  onTap: () => _selectTable(table),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildRecordPanel() {
    if (_selectedTable == null) {
      return const Center(
        child: Text(
          'Selecione uma tabela para ver os registros.',
          style: TextStyle(color: Color(0xFF9AA7BD)),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _selectedTable!,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              FilledButton.icon(
                onPressed: () => _openRecordEditor(),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Adicionar'),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Voltar às tabelas',
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 16),
                onPressed: () => setState(() => _selectedTable = null),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (_loadingRecords)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_records.isEmpty)
          const Expanded(
            child: Center(
              child: Text(
                'Nenhum registro nesta tabela.',
                style: TextStyle(color: Color(0xFF9AA7BD)),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: _records.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final record = _records[i];
                return _RecordCard(
                  record: record,
                  onEdit: () => _openRecordEditor(existing: record),
                  onDelete: () => _deleteRecord(record),
                );
              },
            ),
          ),
      ],
    );
  }
}

// ──────────────────────────────────────────────
// Card de um registro
// ──────────────────────────────────────────────
class _RecordCard extends StatelessWidget {
  const _RecordCard({
    required this.record,
    required this.onEdit,
    required this.onDelete,
  });

  final Map<String, dynamic> record;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final id = record['id']?.toString() ?? '?';
    final preview = record.entries
        .where((e) => e.key != 'id' && e.key != 'action_hash')
        .take(3)
        .map((e) => '${e.key}: ${e.value}')
        .join('  ·  ');

    return Card(
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        title: Text(
          id,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: preview.isEmpty
            ? null
            : Text(
                preview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              tooltip: 'Editar',
              onPressed: onEdit,
            ),
            IconButton(
              icon: Icon(
                Icons.delete_outline,
                size: 18,
                color: Theme.of(context).colorScheme.error,
              ),
              tooltip: 'Eliminar',
              onPressed: onDelete,
            ),
          ],
        ),
        onTap: onEdit,
      ),
    );
  }
}

// ──────────────────────────────────────────────
// Tela de edição / adição de um registro
// ──────────────────────────────────────────────
class _RecordEditorPage extends StatefulWidget {
  const _RecordEditorPage({
    required this.database,
    required this.table,
    this.existing,
  });

  final EnXDB database;
  final String table;
  final Map<String, dynamic>? existing;

  @override
  State<_RecordEditorPage> createState() => _RecordEditorPageState();
}

class _RecordEditorPageState extends State<_RecordEditorPage> {
  late final TextEditingController _jsonController;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.existing != null
        ? Map<String, dynamic>.from(widget.existing!)
        : <String, dynamic>{};

    // Remove campos gerenciados automaticamente para não confundir o user
    initial.remove('action_hash');

    _jsonController = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(initial),
    );
  }

  @override
  void dispose() {
    _jsonController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final raw = jsonDecode(_jsonController.text.trim());
      if (raw is! Map) {
        throw const FormatException('O JSON precisa ser um objeto.');
      }
      final data = Map<String, dynamic>.from(raw);

      if (_isEdit) {
        final id = widget.existing!['id']?.toString() ?? '';
        await widget.database.update(widget.table, id, data);
      } else {
        await widget.database.insert(widget.table, data);
      }

      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isEdit ? 'Editar registro' : 'Novo registro',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_rounded, size: 18),
              label: Text(_saving ? 'Salvando...' : 'Salvar'),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tabela: ${widget.table}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Edite o JSON do registro. Os campos id, created_at e action_hash são gerenciados automaticamente.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            Expanded(
              child: TextField(
                controller: _jsonController,
                enabled: !_saving,
                maxLines: null,
                expands: true,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.5,
                ),
                decoration: InputDecoration(
                  alignLabelWithHint: true,
                  labelText: 'JSON do registro',
                  fillColor: const Color(0xFF101827),
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  labelStyle: const TextStyle(color: Color(0xFF9AA7BD)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}