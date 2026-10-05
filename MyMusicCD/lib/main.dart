import 'dart:io';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'models/project.dart';
import 'models/track.dart';
import 'services/cd_service.dart';
import 'services/native_file_dialog.dart';
import 'services/output_dir.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 启动时创建自动输出目录并清空历史残留文件
  await OutputDir.prepare();
  runApp(const MyMusicCDApp());
}

class MyMusicCDApp extends StatefulWidget {
  const MyMusicCDApp({super.key});

  @override
  State<MyMusicCDApp> createState() => _MyMusicCDAppState();
}

class _MyMusicCDAppState extends State<MyMusicCDApp> {
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    // 退出时清空自动输出目录（窗口关闭时另由原生层兜底清空）
    _lifecycleListener = AppLifecycleListener(
      onDetach: OutputDir.clear,
      onExitRequested: () async {
        await OutputDir.clear();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '我的音乐CD',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const ProjectManager(),
    );
  }
}

class ProjectManager extends StatefulWidget {
  const ProjectManager({super.key});

  @override
  State<ProjectManager> createState() => _ProjectManagerState();
}

class _ProjectManagerState extends State<ProjectManager> {
  final CdService _service = CdService();
  final TextEditingController _projectNameController = TextEditingController();
  List<BurnDevice> _devices = [];
  String? _selectedDevice;
  String? _projectFilePath;
  CdProject? _project;

  int _capacityMinutes = 80;
  bool _blank = false;

  List<Track> _tracks = [];
  ScanResult? _scanResult;
  bool _importing = false;
  bool _burning = false;
  bool _creatingIso = false;
  String _status = '';
  double _progress = 0;
  String _currentFile = '';

  @override
  void initState() {
    super.initState();
    _scanDevices();
  }

  @override
  void dispose() {
    _projectNameController.dispose();
    super.dispose();
  }

  Future<void> _scanDevices() async {
    final devices = await _service.listBurnDevices();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      if (devices.isEmpty) {
        _selectedDevice = null;
      } else if (!_devices.any((d) => d.path == _selectedDevice)) {
        _selectedDevice = devices.first.path;
      }
    });
  }

  Future<void> _newProject() async {
    final dir = await _pickSrcDir();
    if (dir == null) return;
    final projectName = _projectNameController.text.trim().isNotEmpty
        ? _projectNameController.text.trim()
        : 'MyCDProject';
    final project = CdProject(name: projectName);
    final projectPath = p.join(dir.path, '${projectName.toLowerCase().replaceAll(' ', '_')}.mycd');
    await _service.saveProject(project, projectPath);
     setState(() {
       _project = project;
       _projectFilePath = projectPath;
       _tracks = _projectTracksToTracks(project.tracks);
       _status = '';
       _progress = 0;
       _currentFile = '';
      });
     _evaluate();
   }

   Future<void> _openProject() async {
    final projectPath = await _pickProjectFile('打开项目');
    if (projectPath == null) return;
    try {
      final project = await _service.loadProject(projectPath);
       setState(() {
         _project = project;
         _projectFilePath = projectPath;
         _tracks = _projectTracksToTracks(project.tracks);
         _status = '';
         _progress = 0;
          _currentFile = '';
        });
       _evaluate();
     } catch (e) {
       _showError('打开项目失败: $e');
    }
  }

  Future<void> _saveProject() async {
    if (_project == null) return;
    final file = await _pickProjectFile('保存项目');
    if (file == null) return;
    try {
      await _service.saveProject(_project!, file);
      setState(() {
        _projectFilePath = file;
        _status = '项目已保存';
      });
    } catch (e) {
      _showError('保存项目失败: $e');
    }
  }

  List<Track> _projectTracksToTracks(List<ProjectTrack> projectTracks) {
    return List.generate(projectTracks.length, (i) => Track(
      path: projectTracks[i].path,
      name: projectTracks[i].name,
      durationSec: projectTracks[i].durationSec,
      index: projectTracks[i].index,
    ));
  }

  Future<void> _addAudioFiles() async {
    if (_project == null) {
      _showError('请先新建或打开一个项目');
      return;
    }

    final paths = await NativeFileDialog.pickFiles(
      title: '选择音频文件',
      filterName: '音频文件',
      extensions: CdService.audioExtensions.toList(),
      multiple: true,
    );
    if (paths.isEmpty) return;

    final files = paths.map((path) => File(path)).toList();
    await _appendTracks(files);
  }

  Future<void> _addTracksFromDir() async {
    if (_project == null) {
      _showError('请先新建或打开一个项目');
      return;
    }

    final dir = await _pickSrcDir();
    if (dir == null) return;

    List<File> files;
    try {
      files = await _service.scanDirectory(dir.path);
    } catch (e) {
      _showError('扫描失败: $e');
      return;
    }

    if (files.isEmpty) {
      _showError('目录中没有找到音频文件');
      return;
    }
    await _appendTracks(files);
  }

  Future<void> _appendTracks(List<File> files) async {
    final savePath = _projectFilePath;
    if (_project == null || savePath == null) {
      _showError('请先新建或打开一个项目');
      return;
    }
    if (files.isEmpty) {
      _showError('未选择音频文件');
      return;
    }

    final existing = _project!.tracks.map((t) => t.path).toSet();
    final newFiles = files.where((f) => !existing.contains(f.path)).toList();
    final skipped = files.length - newFiles.length;
    if (newFiles.isEmpty) {
      _showError('所选文件均已存在于项目中');
      return;
    }

    setState(() {
      _importing = true;
      _progress = 0;
      _status = '正在导入 0/${newFiles.length}...';
    });

    final updated = List<ProjectTrack>.from(_project!.tracks);

    try {
      for (int i = 0; i < newFiles.length; i++) {
        final path = newFiles[i].path;
        final name = p.basename(path);
        updated.add(ProjectTrack(
          path: path,
          name: name,
          durationSec: await _service.getDuration(path),
        ));

        final preview = List<ProjectTrack>.generate(
          updated.length,
          (j) => updated[j].copyWith(index: j + 1),
        );
        setState(() {
          _progress = (i + 1) / newFiles.length;
          _status = '导入中 [${i + 1}/${newFiles.length}] $name';
          _tracks = _projectTracksToTracks(preview);
        });
      }

      for (int i = 0; i < updated.length; i++) {
        updated[i] = updated[i].copyWith(index: i + 1);
      }

      final project = _project!.copyWith(tracks: updated);
      await _service.saveProject(project, savePath);

        setState(() {
          _project = project;
          _tracks = _projectTracksToTracks(project.tracks);
          _importing = false;
          _status = skipped > 0
              ? '已导入 ${newFiles.length} 个音频文件，跳过 $skipped 个重复项'
              : '已导入 ${newFiles.length} 个音频文件';
        });
       _evaluate();
     } catch (e) {
      setState(() { _importing = false; _status = ''; });
      _showError('导入失败: $e');
    }
  }

  Future<void> _persist() async {
    final savePath = _projectFilePath;
    if (_project == null || savePath == null) return;
    try {
      await _service.saveProject(_project!, savePath);
    } catch (e) {
      _showError('保存项目失败: $e');
    }
  }

  CdProject _removeTrackFromProjectCdProject(int index) {
    final updatedTracks = _project!.tracks.where((t) => t.index != index).toList();
    for (int i = 0; i < updatedTracks.length; i++) {
      updatedTracks[i] = updatedTracks[i].copyWith(index: i + 1);
    }
    return _project!.copyWith(tracks: updatedTracks);
  }

  Future<void> _removeTrack(int index) async {
    setState(() {
      _project = _removeTrackFromProjectCdProject(index);
      _tracks = _projectTracksToTracks(_project!.tracks);
    });
     await _persist();
     _evaluate();
   }

   Future<void> _reorderTracks(int oldIndex, int newIndex) async {
    final updatedProject = _service.reorderTracksInProject(_project!, oldIndex, newIndex);
    setState(() {
      _project = updatedProject;
      _tracks = _projectTracksToTracks(_project!.tracks);
    });
     await _persist();
     _evaluate();
   }

  Future<void> _burn() async {
    if (_tracks.isEmpty) {
      _showError('请先添加音乐文件到项目');
      return;
    }
    if (_scanResult != null && !_scanResult!.fits) {
      _showError('音乐总时长超出 CD 容量，无法继续');
      return;
    }

    final outDir = OutputDir.path;

    final device = _selectedDevice;
    if (device == null || device.isEmpty) {
      _showError('请指定刻录机');
      return;
    }

    setState(() {
      _burning = true;
      _status = '正在刻录...';
    });

    try {
      final result = await _service.convert(
        _tracks,
        outDir,
        onProgress: (current, total, name) {
          setState(() {
            _progress = current / total;
            _currentFile = name;
            _status = '转换中 [$current/$total] $name';
          });
        },
      );

      if (result.wavPaths.isEmpty) {
        _showError('没有成功转换任何文件');
        setState(() { _burning = false; _status = ''; });
        return;
      }

      if (_blank) {
        await _service.blankCdRw(device);
      }

      final process = await _service.burn(
        device: device,
        wavPaths: result.wavPaths,
        blank: _blank,
      );

      process.stdout.listen((data) {});
      process.stderr.listen((data) {});

      final exitCode = await process.exitCode;
      if (exitCode == 0) {
        setState(() { _burning = false; _status = '刻录完成'; });
      } else {
        setState(() { _burning = false; _status = '刻录失败'; });
      }

      for (final wav in result.wavPaths) {
        try {
          await File(wav).delete();
        } catch (_) {}
      }
      try {
        await File(result.cuePath).delete();
      } catch (_) {}
    } catch (e) {
      _showError('刻录失败: $e');
      setState(() { _burning = false; _status = ''; });
    }
  }

  Future<void> _createIso() async {
    if (_tracks.isEmpty) {
      _showError('请先添加音乐文件到项目');
      return;
    }
    if (_scanResult != null && !_scanResult!.fits) {
      _showError('音乐总时长超出 CD 容量，无法继续');
      return;
    }

    final savePath = await NativeFileDialog.saveFile(
      title: '保存 ISO 镜像',
      fileName: '${_project?.name ?? 'music'}.iso',
      filterName: 'ISO 镜像文件',
      extensions: ['iso'],
    );
    if (savePath == null) return;

    final outDir = OutputDir.path;

    setState(() {
      _creatingIso = true;
      _progress = 0;
      _status = '正在转换...';
    });

    try {
      final result = await _service.convert(
        _tracks,
        outDir,
        onProgress: (current, total, name) {
          setState(() {
            _progress = current / total;
            _currentFile = name;
            _status = '转换中 [$current/$total] $name';
          });
        },
      );

      if (result.wavPaths.isEmpty) {
        setState(() { _creatingIso = false; _status = ''; });
        _showError('没有成功转换任何文件');
        return;
      }

      setState(() {
        _progress = 1;
        _currentFile = '';
        _status = '正在生成 ISO...';
      });

      final process = await _service.createIso(
        wavPaths: result.wavPaths,
        cuePath: result.cuePath,
        isoPath: savePath,
        volumeLabel: _project?.name ?? '我的音乐CD',
      );
      process.stdout.listen((data) {});
      process.stderr.listen((data) {});

      final exitCode = await process.exitCode;
      if (exitCode == 0) {
        setState(() { _creatingIso = false; _status = ''; });
        _showMessage('ISO 已生成: $savePath');
      } else {
        setState(() { _creatingIso = false; _status = ''; });
        _showError('ISO 生成失败 (退出码 $exitCode)');
      }

      for (final wav in result.wavPaths) {
        try { await File(wav).delete(); } catch (_) {}
      }
      try { await File(result.cuePath).delete(); } catch (_) {}
    } catch (e) {
      _showError('生成 ISO 失败: $e');
      setState(() { _creatingIso = false; _status = ''; });
    }
  }

  Future<Directory?> _pickSrcDir() async {
    final dir = await NativeFileDialog.getDirectoryPath(title: '选择目录');
    return dir != null ? Directory(dir) : null;
  }

  Future<String?> _pickProjectFile(String title) async {
    final paths = await NativeFileDialog.pickFiles(
      title: title,
      filterName: '我的音乐CD项目文件',
      extensions: ['mycd'],
    );
    return paths.isEmpty ? null : paths.first;
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  void _showMessage(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  String _formatDuration(int sec) {
    final m = sec ~/ 60;
    final s = sec % 60;
    return '$m 分 ${s.toString().padLeft(2, '0')} 秒';
  }

  Widget _buildTrackList() {
    if (_tracks.isEmpty) {
      return Center(
        child: Text(
          _project == null
              ? '请先通过右上角菜单新建或打开项目'
              : '点击左侧「新增音频文件」或「导入目录中所有音频文件」添加音轨',
          style: const TextStyle(color: Colors.grey),
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView.builder(
      itemCount: _tracks.length,
      itemBuilder: (ctx, i) {
        final t = _tracks[i];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: ListTile(
            dense: true,
            leading: CircleAvatar(
              radius: 14,
              child: Text('${t.index}', style: const TextStyle(fontSize: 11)),
            ),
            title: Text(t.name, overflow: TextOverflow.ellipsis),
            subtitle: Text(t.durationFormatted),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_upward, size: 16),
                  tooltip: '移动上去',
                  onPressed: _importing ? null : () => _reorderTracks(t.index, t.index - 1),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.arrow_downward, size: 16),
                  tooltip: '移动下去',
                  onPressed: _importing ? null : () => _reorderTracks(t.index, t.index + 1),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  tooltip: '移除音轨',
                  onPressed: _importing ? null : () => _removeTrack(t.index),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildResultCard() {
    final result = _scanResult!;
    final fits = result.fits;
    return Card(
      margin: const EdgeInsets.all(8),
      color: fits ? Colors.green.withValues(alpha: 0.1) : Colors.red.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              fits ? Icons.check_circle : Icons.error,
              color: fits ? Colors.green : Colors.red,
              size: 32,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fits ? '可以刻录' : '超出容量',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: fits ? Colors.green : Colors.red,
                    ),
                  ),
                  Text(
                    '总时长: ${_formatDuration(result.totalDurationSec)} | '
                    '占用: ${result.totalDurationSec * CdCapacity.bytesPerSec ~/ 1024 ~/ 1024} MB | '
                    'CD: $_capacityMinutes 分钟',
                  ),
                  if (fits)
                    Text('剩余 ${result.remainingMb} MB')
                  else
                    Text('超出 ${result.overMb} MB', style: const TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressCard() {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_status, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _progress),
            if (_currentFile.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(_currentFile, style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildProjectCard() {
    final project = _project!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.album, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    project.name,
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${_tracks.length} 首',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            if (_projectFilePath != null) ...[
              const SizedBox(height: 4),
              Text(
                _projectFilePath!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _importing ? null : _addAudioFiles,
              icon: const Icon(Icons.library_music),
              label: const Text('新增音频文件'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _importing ? null : _addTracksFromDir,
              icon: _importing
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.folder_open),
              label: const Text('导入目录中所有音频文件'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProjectSetupCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('新建项目', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _projectNameController,
              decoration: const InputDecoration(
                labelText: '项目名称',
                hintText: 'MyCDProject',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _newProject(),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _newProject,
              icon: const Icon(Icons.create_new_folder),
              label: const Text('新建项目'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlPanel() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_project == null) ...[
            _buildProjectSetupCard(),
            const SizedBox(height: 12),
          ] else ...[
            _buildProjectCard(),
            const SizedBox(height: 12),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('CD 设置', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: _capacityMinutes,
                    decoration: const InputDecoration(
                      labelText: 'CD 容量',
                      border: OutlineInputBorder(),
                    ),
                    items: CdCapacity.supportedMinutes.map((m) => DropdownMenuItem(
                      value: m,
                      child: Text('$m 分钟'),
                    )).toList(),
                    onChanged: (v) => setState(() => _capacityMinutes = v!),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          key: ValueKey(_devices.map((d) => d.path).join('|')),
                          initialValue: _devices.any((d) => d.path == _selectedDevice)
                              ? _selectedDevice
                              : null,
                          decoration: const InputDecoration(
                            labelText: '刻录机',
                            border: OutlineInputBorder(),
                          ),
                          hint: const Text('未找到刻录机'),
                          items: _devices.map((d) => DropdownMenuItem(
                            value: d.path,
                            child: Text(
                              d.description,
                              overflow: TextOverflow.ellipsis,
                            ),
                          )).toList(),
                          onChanged: (v) => setState(() => _selectedDevice = v),
                        ),
                      ),
                      IconButton(
                        onPressed: _scanDevices,
                        icon: const Icon(Icons.refresh),
                        tooltip: '刷新刻录机列表',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('选项', style: Theme.of(context).textTheme.titleMedium),
                  CheckboxListTile(
                    title: const Text('刻录前擦除 CD-RW'),
                    value: _blank,
                    onChanged: (v) => setState(() => _blank = v!),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: (_burning || _creatingIso || _importing ||
                    _selectedDevice == null)
                ? null
                : _burn,
            icon: const Icon(Icons.disc_full),
            label: const Text('转换并刻录'),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: (_burning || _creatingIso || _importing) ? null : _createIso,
            icon: const Icon(Icons.save),
            label: const Text('生成 ISO 镜像'),
          ),
        ],
      ),
    );
  }

  Widget _buildMainPanel() {
    return Column(
      children: [
        if (_scanResult != null) _buildResultCard(),
        if (_importing || _burning || _creatingIso) _buildProgressCard(),
        Expanded(
          child: _buildTrackList(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的音乐CD'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          PopupMenuButton<String>(
            onSelected: (String value) {
              if (value == 'new') {
                _newProject();
              } else if (value == 'open') {
                _openProject();
              } else if (value == 'save' && _project != null) {
                _saveProject();
              }
            },
            itemBuilder: (BuildContext context) => [
              const PopupMenuItem<String>(
                value: 'new',
                child: Row(
                  children: [
                    Icon(Icons.folder),
                    SizedBox(width: 8),
                    Text('新建项目'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'open',
                child: Row(
                  children: [
                    Icon(Icons.folder_open),
                    SizedBox(width: 8),
                    Text('打开项目'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'save',
                child: Row(
                  children: [
                    Icon(Icons.save),
                    SizedBox(width: 8),
                    Text('保存项目'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Row(
        children: [
          SizedBox(
            width: 380,
            child: _buildControlPanel(),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: _buildMainPanel(),
          ),
        ],
      ),
    );
  }

  Future<void> _evaluate() async {
    if (_project == null) {
      _showError('请先新建或打开一个项目');
      return;
    }

    setState(() {
      _status = '正在评估...';
    });

    try {
      final capacity = CdCapacity(_capacityMinutes);
      final result = await _service.evaluate(_tracks, capacity);

      setState(() {
        _scanResult = result;
        _status = '评估完成';
      });
    } catch (e) {
      _showError('评估失败: $e');
      setState(() { _status = ''; });
    }
  }
}