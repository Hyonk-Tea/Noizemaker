#!/usr/bin/env python3
import os
import re
import configparser

from PyQt6.QtWidgets import *
from PyQt6.QtCore import Qt
from PyQt6.QtGui import QColor, QPixmap, QImage, QPainter

from sc5_format import (
    GAME_TO_INTERNAL,
    INV,
    TICK_CYCLE,
    Step,
    Entry,
    parse,
    total_ticks,
    default_gap,
    implied_last_gap,
    local_id_list_info,
    is_raw_byte,
    step_display_name,
)

from sc5_rebuild import (
    apply,
    normalize_shifted_start_delay_layout,
)

def app_dir():
    return os.path.abspath(os.path.dirname(__file__))

def reports_config_path():
    return os.path.join(app_dir(), "reports.ini")

def load_reports_config():
    """Load user-editable section labels from reports.ini.

    Supported sections:
      [R1]       per-report labels, preferred when the opened file looks like R1
      [default]  fallback labels
      [sections] legacy/simple fallback labels

    Example:
      [R1]
      pd = First Dance
      ps = Elevators
      ps20 = The Rhythm Rogues
    """
    cfg = configparser.ConfigParser()
    path = reports_config_path()
    if os.path.exists(path):
        cfg.read(path, encoding="utf-8")
    return cfg

def infer_report_key(path):
    """Infer report key like R1 from filenames such as r11_sh.bin or R1.BIN."""
    if not path:
        return "default"
    name = os.path.basename(path).lower()
    m = re.match(r"r(\d)", name)
    if m:
        return f"R{m.group(1)}"
    return "default"

def section_labels_for_file(path):
    """Return {prefix: label} for the opened file. Longest prefix wins later."""
    cfg = load_reports_config()
    labels = {}
    for section in ("sections", "default", infer_report_key(path)):
        if cfg.has_section(section):
            for key, value in cfg.items(section):
                key = key.strip().lower()
                value = value.strip()
                if key and value:
                    labels[key] = value
    return labels

def section_for_base(base, labels):
    """Return (prefix, label) for the longest configured prefix matching base."""
    b = (base or "").lower()
    for prefix in sorted(labels.keys(), key=len, reverse=True):
        if b.startswith(prefix):
            return prefix, labels[prefix]
    return None, None

FONT_ATLAS_ROWS = [
    " !\"#$%&'[]*+",
    "_./012345678",
    "9:;<=>?@ABCD",
    "EFGHIJKLMNOP",
    "QRSTUVWXYZ[|",
    "]^=`abcdefgh",
    "ijklmnopqrst",
    "uvwxyz{\\}~",
]
def find_game_asset(start_path, relative_path):
    """Search upward from the opened .bin for a game asset path."""
    if not start_path:
        return None
    cur = os.path.abspath(os.path.dirname(start_path))
    for _ in range(8):
        candidate = os.path.join(cur, relative_path)
        if os.path.exists(candidate):
            return candidate
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    return None

class BitmapFontRenderer:
    """Tiny renderer for SC5P2's 30px-pitch TGA font atlas."""
    def __init__(self, path, cell_w=30, cell_h=30):
        self.path = path
        self.cell_w = cell_w
        self.cell_h = cell_h
        self.char_to_index = {}
        for row, chars in enumerate(FONT_ATLAS_ROWS):
            for col, ch in enumerate(chars):
                # If duplicate characters exist, keep the first mapping.
                self.char_to_index.setdefault(ch, (row, col))
        self.image = QImage(path)
        if self.image.isNull():
            raise ValueError(f"Could not load bitmap font atlas: {path}")

    def render_pixmap(self, text, scale=1):
        text = text or ""
        width = max(1, len(text) * self.cell_w)
        height = self.cell_h
        canvas = QImage(width, height, QImage.Format.Format_ARGB32)
        canvas.fill(Qt.GlobalColor.transparent)
        painter = QPainter(canvas)
        try:
            x = 0
            for ch in text:
                row_col = self.char_to_index.get(ch)
                if row_col is not None:
                    row, col = row_col
                    source_x = col * self.cell_w
                    source_y = row * self.cell_h
                    painter.drawImage(x, 0, self.image, source_x, source_y, self.cell_w, self.cell_h)
                x += self.cell_w
        finally:
            painter.end()
        pix = QPixmap.fromImage(canvas)
        if scale != 1:
            pix = pix.scaled(width * scale, height * scale, Qt.AspectRatioMode.KeepAspectRatio,
                             Qt.TransformationMode.FastTransformation)
        return pix

def check_min_safe_sc(parent_widget, entry, new_sc):
    """
    Returns True if safe to proceed, False (and shows a dialog) if not.
    entry may be None (always safe).
    """
    if entry is None:
        return True
    mssc = entry.min_safe_sc
    if new_sc < mssc:
        QMessageBox.warning(
            parent_widget,
            "Hardlock risk - change blocked",
            f"<b>{entry.name}</b> has animation data in its rest_body that references "
            f"step index <b>{mssc}</b> (1-based).<br><br>"
            f"Reducing the step count below <b>{mssc}</b> causes the game engine to "
            f"dereference a step that no longer exists -> <b>hardlock on load</b>.<br><br>"
            f"Minimum safe step count: <b>{mssc}</b>&nbsp;&nbsp;|&nbsp;&nbsp;"
            f"You attempted: <b>{new_sc}</b><br><br>"
            f"You can freely change step <i>codes</i> (move types) - "
            f"just keep the total count ≥ {mssc}."
        )
        return False
    return True

class StepToken(QFrame):
    """A single step pill.  Left-click name = remove.  Right-click name = edit raw byte."""
    def __init__(self, idx, step, timing, on_remove, on_code_edit, on_gap_change, is_last=False):
        super().__init__()
        self.idx           = idx
        self.step          = step
        self.timing        = timing
        self.on_gap_change = on_gap_change
        self.on_code_edit  = on_code_edit
        self.is_last       = is_last
        self.setFrameShape(QFrame.Shape.StyledPanel)

        raw = is_raw_byte(step.code)
        if raw:
            self.setStyleSheet(
                "StepToken{background:#3a2a1a;border:1px solid #8a6020;border-radius:4px;}"
            )
        else:
            self.setStyleSheet(
                "StepToken{background:#333;border:1px solid #555;border-radius:4px;}"
            )

        lay = QHBoxLayout(self)
        lay.setContentsMargins(4, 2, 4, 2)
        lay.setSpacing(3)

        move_name = step_display_name(step.code)
        name_btn  = QPushButton(move_name)
        name_btn.setFixedHeight(22)
        name_btn.setMaximumWidth(84)
        if raw:
            name_btn.setStyleSheet(
                "QPushButton{background:#4a3010;border:none;padding:0 4px;color:#e8a040;}"
                "QPushButton:hover{background:#5a4020;}"
            )
            name_btn.setToolTip("Click to remove - Right-click to edit byte value")
        else:
            name_btn.setStyleSheet(
                "QPushButton{background:#2a2a2a;border:none;padding:0 4px;}"
                "QPushButton:hover{background:#3a3a3a;}"
            )
            name_btn.setToolTip("Click to remove - Right-click to override as raw byte")
        name_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        name_btn.clicked.connect(lambda: on_remove(idx))
        name_btn.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        name_btn.customContextMenuRequested.connect(lambda _: self._edit_code())
        lay.addWidget(name_btn)

        if not is_last:
            self.gap_btn = QPushButton(self._gap_text())
            self.gap_btn.setFixedHeight(22)
            self.gap_btn.setMaximumWidth(64)
            self.gap_btn.setStyleSheet(
                "QPushButton{background:#3a3a3a;border:1px solid #666;"
                "border-radius:2px;font-size:10px;color:#aaa;padding:0 3px;}"
                "QPushButton:hover{background:#484848;color:#ddd;}"
            )
            self.gap_btn.setCursor(Qt.CursorShape.PointingHandCursor)
            self.gap_btn.setToolTip("Click to cycle gap - Right-click to enter value")
            self.gap_btn.clicked.connect(self._cycle_gap)
            self.gap_btn.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
            self.gap_btn.customContextMenuRequested.connect(self._edit_gap)
            lay.addWidget(self.gap_btn)
        else:
            self.gap_btn = QLabel("->")
            self.gap_btn.setStyleSheet("color:#555;font-size:10px;")
            self.gap_btn.setToolTip("Last step gap implied by loop length")
            lay.addWidget(self.gap_btn)

    def _gap_text(self):
        return f"{self.step.gap}t"

    def _cycle_gap(self):
        try:
            idx = TICK_CYCLE.index(self.step.gap)
            nxt = TICK_CYCLE[(idx + 1) % len(TICK_CYCLE)]
        except ValueError:
            nxt = TICK_CYCLE[0]
        self.step.gap = nxt
        self.gap_btn.setText(self._gap_text())
        self.on_gap_change()

    def _edit_gap(self):
        val, ok = QInputDialog.getInt(
            self, "Gap (ticks)",
            f"Enter gap after this step (ticks).\n"
            f"Total loop = {total_ticks(self.timing)}t  (timing={self.timing}*6)\n"
            f"Common: 6=1/16  12=1/8  24=1/4  48=1/2",
            self.step.gap, 1, 9999
        )
        if ok:
            self.step.gap = val
            self.gap_btn.setText(self._gap_text())
            self.on_gap_change()

    def _edit_code(self):
        """Right-click on the pill name: change the raw byte value."""
        current_hex = f"0x{self.step.code:02X}"
        text, ok = QInputDialog.getText(
            self, "Edit step byte",
            "Enter raw byte value (hex, e.g. 0x41 or 65):",
            text=current_hex
        )
        if not ok or not text.strip():
            return
        try:
            val = int(text.strip(), 16)
            if not 0 <= val <= 255:
                raise ValueError
        except ValueError:
            QMessageBox.warning(self, "Invalid", f"'{text}' is not a valid byte (0x00-0xFF).")
            return
        self.step.code = val
        self.on_code_edit()   # SeqWidget will rebuild pills

    def refresh_last(self, implied_ticks):
        if self.is_last and isinstance(self.gap_btn, QLabel):
            self.gap_btn.setText(f"->{implied_ticks}t")

class SeqWidget(QWidget):
    def __init__(self):
        super().__init__()
        self.steps           = []
        self.timing          = 16
        self._remove_cb      = None
        self._code_edit_cb   = None
        self._gap_change_cb  = None
        lay = QHBoxLayout(self)
        lay.setContentsMargins(4, 3, 4, 3)
        lay.setSpacing(4)
        lay.addStretch()

    def set_seq(self, steps, timing, remove_cb, code_edit_cb, gap_change_cb):
        self.steps          = steps
        self.timing         = timing
        self._remove_cb     = remove_cb
        self._code_edit_cb  = code_edit_cb
        self._gap_change_cb = gap_change_cb
        self._rebuild()

    def _rebuild(self):
        lay = self.layout()
        while lay.count():
            item = lay.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        if not self.steps:
            lbl = QLabel("(empty)")
            lbl.setStyleSheet("color:#666;font-style:italic;background:transparent;")
            lay.addWidget(lbl)
        else:
            for i, step in enumerate(self.steps):
                is_last = (i == len(self.steps) - 1)
                tok = StepToken(
                    i, step, self.timing,
                    self._remove_cb,
                    self._on_code_edit,
                    self._on_gap_change,
                    is_last
                )
                lay.addWidget(tok)
            self._refresh_implied()
        lay.addStretch()

    def _on_gap_change(self):
        self._refresh_implied()
        if self._gap_change_cb:
            self._gap_change_cb()

    def _on_code_edit(self):
        self._rebuild()
        if self._code_edit_cb:
            self._code_edit_cb()

    def _refresh_implied(self):
        if not self.steps:
            return
        stored_gaps = [s.gap for s in self.steps[:-1]]
        implied = implied_last_gap(self.timing, stored_gaps)
        lay = self.layout()
        for i in range(lay.count()):
            w = lay.itemAt(i).widget()
            if isinstance(w, StepToken) and w.is_last:
                w.refresh_last(implied)
                break

    def implied_summary(self):
        if not self.steps:
            return ""
        stored  = [s.gap for s in self.steps[:-1]]
        implied = implied_last_gap(self.timing, stored)
        return f"last gap = {implied}t  (total loop = {total_ticks(self.timing)}t)"

STYLESHEET = """
QWidget {
    background-color: #2b2b2b; color: #d4d0c8;
    font-family: Tahoma, 'DejaVu Sans', sans-serif; font-size: 12px;
}
QMainWindow { background-color: #2b2b2b; }
QSplitter::handle { background: #3c3c3c; width: 3px; }
QTreeWidget {
    background: #1e1e1e; color: #d4d0c8;
    border: 1px solid #555; outline: none; font-size: 12px;
}
QTreeWidget::item { padding: 2px 4px; }
QTreeWidget::item:hover { background: #333; }
QTreeWidget::item:selected { background: #4a6fa5; color: #fff; }
QHeaderView::section {
    background: #3a3a3a; color: #bbb;
    border: none; border-bottom: 1px solid #555; padding: 3px 6px; font-size: 11px;
}
QLineEdit {
    background: #1e1e1e; color: #d4d0c8;
    border: 1px solid #555; padding: 3px 6px;
    selection-background-color: #4a6fa5;
}
QLineEdit:focus { border-color: #7a9fd4; }
QPushButton {
    background: #3a3a3a; color: #d4d0c8;
    border: 1px solid #555; padding: 4px 12px; min-width: 60px;
}
QPushButton:hover { background: #444; border-color: #777; }
QPushButton:pressed { background: #2a2a2a; }
QPushButton:disabled { color: #666; }
QScrollBar:vertical { background: #2b2b2b; width: 12px; border: none; }
QScrollBar::handle:vertical { background: #555; min-height: 20px; border: 1px solid #666; }
QScrollBar::handle:vertical:hover { background: #666; }
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
QScrollBar:horizontal { background: #2b2b2b; height: 12px; border: none; }
QScrollBar::handle:horizontal { background: #555; min-width: 20px; border: 1px solid #666; }
QScrollBar::handle:horizontal:hover { background: #666; }
QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal { width: 0; }
QStatusBar { background: #252525; color: #aaa; border-top: 1px solid #444; font-size: 11px; }

QFrame#SummaryFrame {
    background:#292929; border:1px solid #484848;
}
QLabel#EntryTitle {
    color:#ffffff; font-size:16px; font-weight:bold; min-height:34px;
}
QLabel#StatBox {
    background:#1f1f1f; border:1px solid #4b4b4b;
    color:#d4d0c8; padding:4px 8px;
}
QLabel#StatBoxWarn {
    background:#1f1f1f; border:1px solid #4b4b4b;
    color:#e8a040; padding:4px 8px;
}
QPushButton#PrimaryButton {
    background:#5a2a4a; border-color:#b05f82; color:#ffd0e0;
}
QGroupBox {
    color: #bbb; border: 1px solid #484848;
    margin-top: 8px; padding-top: 4px; font-size: 11px;
}
QGroupBox::title { subcontrol-origin: margin; left: 8px; padding: 0 4px; color: #999; }
QScrollArea { border: 1px solid #555; background: #1e1e1e; }
QLabel { background: transparent; }
QMenuBar { background: #252525; color: #ccc; border-bottom: 1px solid #444; }
QMenuBar::item:selected { background: #3a3a3a; }
QMenu { background: #2b2b2b; border: 1px solid #555; }
QMenu::item:selected { background: #4a6fa5; }
StepToken { background:#333; border:1px solid #555; border-radius:4px; }
"""


def timing_summary_text(timing):
    total = total_ticks(timing)
    beats = timing // 4 if timing % 4 == 0 else timing / 4
    beats_text = f"{beats:g}" if isinstance(beats, float) else str(beats)
    return f"Total: {total}t ({beats_text} beats | {timing} 1/4ths | 6t each)"

class App(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("SC5P2 Step Patcher")
        self.resize(980, 580)
        self.buf        = None
        self.path       = None
        self.entries    = []
        self.mods       = {}
        self.seq        = []
        self.anim_indices = []  # Indices for animation blocks (empty if no anims)
        self.cur_timing = 16
        self.cur_start_delay = 0
        self.auto_repaired_entries = []
        self.bitmap_font = None
        self.cur_entry  = None
        self._build_ui()
        self.statusBar().showMessage("No file loaded.")

    def _build_ui(self):
        mb = self.menuBar()
        fm = mb.addMenu("File")
        a = fm.addAction("Open...");             a.triggered.connect(self.open_file);  a.setShortcut("Ctrl+O")
        a = fm.addAction("Patch (overwrite)");   a.triggered.connect(self.patch_file); a.setShortcut("Ctrl+S")
        fm.addSeparator()
        fm.addAction("Quit").triggered.connect(self.close)

        splitter = QSplitter(Qt.Orientation.Horizontal)
        self.setCentralWidget(splitter)

        left = QWidget(); left.setMaximumWidth(270); left.setMinimumWidth(180)
        ll   = QVBoxLayout(left)
        ll.setContentsMargins(8, 8, 8, 8)
        self.search_box = QLineEdit()
        self.search_box.setPlaceholderText("Search entries...")
        self.search_box.textChanged.connect(self._filter_tree)
        ll.addWidget(self.search_box)

        self.tree = QTreeWidget(); self.tree.setColumnCount(2); self.tree.setHeaderLabels(["Entries", "Type"]); self.tree.setColumnWidth(0, 150)
        self.tree.itemSelectionChanged.connect(self.load_selected)
        ll.addWidget(self.tree)
        splitter.addWidget(left)

        right = QWidget(); rl = QVBoxLayout(right)
        rl.setContentsMargins(10, 8, 10, 8)
        rl.setSpacing(8)

        self.summary_frame = QFrame()
        self.summary_frame.setObjectName("SummaryFrame")
        summary_lay = QHBoxLayout(self.summary_frame)
        summary_lay.setContentsMargins(10, 6, 10, 6)
        summary_lay.setSpacing(8)

        self.entry_lbl = QLabel("...")
        self.entry_lbl.setObjectName("EntryTitle")
        summary_lay.addWidget(self.entry_lbl, 1)

        self.steps_stat_lbl = QLabel("Steps: -")
        self.steps_stat_lbl.setObjectName("StatBox")
        summary_lay.addWidget(self.steps_stat_lbl)

        self.start_delay_lbl = QLabel("Start delay")
        self.start_delay_lbl.setStyleSheet("color:#aaa;font-size:11px;")
        summary_lay.addWidget(self.start_delay_lbl)

        self.start_delay_spin = QSpinBox()
        self.start_delay_spin.setRange(0, 65535)
        self.start_delay_spin.setSuffix("t")
        self.start_delay_spin.setMaximumWidth(86)
        self.start_delay_spin.setToolTip("Lead-in delay before this sequence starts. Stored after the step bytes; odd step counts include one alignment byte.")
        self.start_delay_spin.valueChanged.connect(self._on_start_delay_change)
        summary_lay.addWidget(self.start_delay_spin)

        self.total_stat_lbl = QLabel("Total: -")
        self.total_stat_lbl.setObjectName("StatBox")
        summary_lay.addWidget(self.total_stat_lbl)

        self.implied_lbl = QLabel("Last gap: -")
        self.implied_lbl.setObjectName("StatBoxWarn")
        summary_lay.addWidget(self.implied_lbl)

        rl.addWidget(self.summary_frame)

        # Sequence display
        seq_grp = QGroupBox("Sequence  (click move to remove - right-click move to edit byte - click gap to cycle - right-click gap to set)")
        sq = QVBoxLayout(seq_grp)
        sq.setContentsMargins(8, 8, 8, 8)
        self.seq_scroll = QScrollArea()
        self.seq_scroll.setFixedHeight(56)
        self.seq_scroll.setWidgetResizable(True)
        self.seq_w = SeqWidget()
        self.seq_scroll.setWidget(self.seq_w)
        sq.addWidget(self.seq_scroll)

        input_row = QHBoxLayout()
        self.seq_input = QLineEdit()
        self.seq_input.setPlaceholderText(
            'Text input: CHU:24 UP:12 RAW:0x41:24 ...'
        )
        self.seq_input.returnPressed.connect(self.parse_text_input)
        input_row.addWidget(self.seq_input)
        clr = QPushButton("Clear"); clr.clicked.connect(self.clear_seq)
        input_row.addWidget(clr)
        apply_btn = QPushButton("Apply to selected"); apply_btn.clicked.connect(self.apply_selected)
        apply_btn.setObjectName("PrimaryButton")
        input_row.addWidget(apply_btn)
        patch_btn = QPushButton("Patch file"); patch_btn.clicked.connect(self.patch_file)
        input_row.addWidget(patch_btn)
        sq.addLayout(input_row)
        rl.addWidget(seq_grp)

        # Add-move grid: holds align below their normal versions.
        moves_grp = QGroupBox("Add move")
        moves_layout = QGridLayout(moves_grp)
        moves_layout.setContentsMargins(8, 8, 8, 8)
        moves_layout.setHorizontalSpacing(6)
        moves_layout.setVerticalSpacing(6)

        base_moves = ["UP", "DOWN", "LEFT", "RIGHT", "CHU", "HEY", "REST"]
        hold_moves = ["HOLDUP", "HOLDDOWN", "HOLDLEFT", "HOLDRIGHT", "HOLDCHU", "HOLDHEY", None]
        for col, name in enumerate(base_moves):
            b = QPushButton(name); b.clicked.connect(lambda _, n=name: self.add_move(n))
            moves_layout.addWidget(b, 0, col)
        for col, name in enumerate(hold_moves):
            if name is None:
                raw_btn = QPushButton("RAW...")
                raw_btn.setStyleSheet(
                    "QPushButton{background:#4a3010;border:1px solid #8a6020;color:#e8a040;}"
                    "QPushButton:hover{background:#5a4020;}"
                )
                raw_btn.setToolTip("Add an arbitrary raw byte step (e.g. 0x41)")
                raw_btn.clicked.connect(self.add_raw_byte)
                moves_layout.addWidget(raw_btn, 1, col)
            else:
                b = QPushButton(name)
                b.setStyleSheet(
                    "QPushButton{background:#2a3a5a;border:1px solid #4a6fa5;color:#9fd4ff;}"
                    "QPushButton:hover{background:#344a6f;}"
                )
                b.clicked.connect(lambda _, n=name: self.add_move(n))
                moves_layout.addWidget(b, 1, col)
        rl.addWidget(moves_grp)

        # Bottom details area. Keep this lighter than the main sequence editor.
        details_row = QHBoxLayout()
        details_row.setSpacing(8)

        timing_grp = QGroupBox("Timing")
        timing_layout = QFormLayout(timing_grp)
        timing_layout.setContentsMargins(8, 8, 8, 8)
        self.timing_lbl = QLabel("")
        self.timing_lbl.setStyleSheet("color:#7a9fd4;")
        self.start_delay_readout_lbl = QLabel("")
        self.final_gap_readout_lbl = QLabel("")
        timing_layout.addRow("Start delay", self.start_delay_readout_lbl)
        timing_layout.addRow("Total loop", self.timing_lbl)
        timing_layout.addRow("Derived final gap", self.final_gap_readout_lbl)
        self.timing_field_lbl = QLabel("")
        timing_layout.addRow("Timing field", self.timing_field_lbl)
        details_row.addWidget(timing_grp, 1)

        self.special_grp = QGroupBox("Special Cases")
        special_layout = QVBoxLayout(self.special_grp)
        special_layout.setContentsMargins(8, 8, 8, 8)
        self.special_info_lbl = QLabel("No special cases detected.")
        self.special_info_lbl.setStyleSheet("color:#888;font-size:11px;")
        special_layout.addWidget(self.special_info_lbl)

        self.rescue_ids_container = QWidget()
        self.rescue_ids_layout = QHBoxLayout(self.rescue_ids_container)
        self.rescue_ids_layout.setContentsMargins(0, 0, 0, 0)
        special_layout.addWidget(self.rescue_ids_container)

        self.anim_info_lbl = QLabel("")
        self.anim_info_lbl.setStyleSheet("color:#888;font-size:11px;")
        special_layout.addWidget(self.anim_info_lbl)
        self.anim_inputs = []
        self.anim_inputs_container = QWidget()
        self.anim_inputs_layout = QHBoxLayout(self.anim_inputs_container)
        self.anim_inputs_layout.setContentsMargins(0,0,0,0)
        special_layout.addWidget(self.anim_inputs_container)

        details_row.addWidget(self.special_grp, 1)

        safety_grp = QGroupBox("Safety")
        safety_layout = QVBoxLayout(safety_grp)
        safety_layout.setContentsMargins(8, 8, 8, 8)
        self.safe_sc_lbl = QLabel("")
        self.safe_sc_lbl.setStyleSheet("color:#e8a040; font-size:11px;")
        safety_layout.addWidget(self.safe_sc_lbl)
        safety_layout.addStretch()
        details_row.addWidget(safety_grp, 1)

        rl.addLayout(details_row)
        rl.addStretch(1)

        splitter.addWidget(right)


    def _try_load_bitmap_font(self):
        if self.bitmap_font is not None:
            return
        asset = find_game_asset(self.path, os.path.join("font", "font_ulala_blue.tga"))
        if not asset:
            return
        try:
            self.bitmap_font = BitmapFontRenderer(asset)
        except Exception:
            self.bitmap_font = None

    def _set_entry_title(self, text):
        self._try_load_bitmap_font()
        if self.bitmap_font is not None and text and text != "..." and not text.endswith("selected"):
            try:
                self.entry_lbl.setPixmap(self.bitmap_font.render_pixmap(text.upper(), scale=1))
                self.entry_lbl.setText("")
                self.entry_lbl.setToolTip(text)
                return
            except Exception:
                pass
        self.entry_lbl.setPixmap(QPixmap())
        self.entry_lbl.setText(text)
        self.entry_lbl.setToolTip("")

    
    def _filter_tree(self, text):
        text = text.strip().lower()
        for i in range(self.tree.topLevelItemCount()):
            parent = self.tree.topLevelItem(i)
            any_visible = False
            for j in range(parent.childCount()):
                child = parent.child(j)
                e = child.data(0, Qt.ItemDataRole.UserRole)
                name = e.name.lower() if isinstance(e, Entry) else child.text(0).lower()
                visible = not text or text in name
                child.setHidden(not visible)
                any_visible = any_visible or visible
            parent.setHidden(not any_visible and bool(text))

    def open_file(self):
        p, _ = QFileDialog.getOpenFileName(self, "Open binary", "", "Binary files (*.bin);;All files (*)")
        if not p: return
        self.path = p
        try:
            with open(p, "rb") as f:
                self.buf = f.read()

            self.buf, self.auto_repaired_entries = normalize_shifted_start_delay_layout(self.buf)
            self.entries   = parse(self.buf)
            self.mods      = {}
            self.seq       = []
            self.cur_start_delay = 0
            self.cur_entry = None
            self.tree.clear()
            groups = {}
            for e in self.entries:
                groups.setdefault(e.base, []).append(e)

            section_labels = section_labels_for_file(self.path)
            previous_section = None
            for base, items in sorted(groups.items()):
                section_prefix, section_label = section_for_base(base, section_labels)
                parent_label = base
                if section_prefix and section_prefix != previous_section:
                    parent_label = f"{base} [{section_label}]"
                previous_section = section_prefix

                parent = QTreeWidgetItem([parent_label, ""])
                self.tree.addTopLevelItem(parent)
                for e in items:
                    badges = []
                    if local_id_list_info(e) is not None:
                        badges.append("RESCUE")
                    if e.start_delay:
                        badges.append("LYRICS")
                    c = QTreeWidgetItem([e.name, "  ".join(badges)])
                    c.setData(0, Qt.ItemDataRole.UserRole, e)
                    if "RESCUE" in badges:
                        c.setForeground(1, QColor("#f5c987"))
                        c.setBackground(1, QColor("#3a2a1a"))
                    elif "LYRICS" in badges:
                        c.setForeground(1, QColor("#ff9fd4"))
                        c.setBackground(1, QColor("#421f2f"))
                    parent.addChild(c)
            self.tree.expandAll()
            self._refresh_seq()
            self._set_entry_title("...")
            self.safe_sc_lbl.setText("")
            if self.auto_repaired_entries:
                repaired = ", ".join(self.auto_repaired_entries)
                self.statusBar().showMessage(
                    f"Loaded {len(self.entries)} entries from {p} - normalized shifted start-delay layout for: {repaired}"
                )
            else:
                self.statusBar().showMessage(f"Loaded {len(self.entries)} entries from {p}")
        except Exception as ex:
            QMessageBox.critical(self, "Error", str(ex))
            import traceback; traceback.print_exc()

    def patch_file(self):
        if not self.buf or not self.path:
            QMessageBox.warning(self, "Warning", "No file loaded"); return
        if not self.mods and not self.auto_repaired_entries:
            QMessageBox.warning(self, "Warning", "No modifications to apply"); return
        patched = apply(self.buf, self.entries, self.mods) if self.mods else self.buf
        with open(self.path, "wb") as f:
            f.write(patched)
        self.auto_repaired_entries = []
        self.statusBar().showMessage(f"Patched {self.path} successfully!")

    def load_selected(self):
        items   = self.tree.selectedItems()
        entries = [i.data(0, Qt.ItemDataRole.UserRole) for i in items]
        entries = [e for e in entries if isinstance(e, Entry)]
        if not entries:
            self._set_entry_title("...")
            self.steps_stat_lbl.setText("Steps: -")
            self.timing_lbl.setText("")
            self.timing_field_lbl.setText("")
            self.total_stat_lbl.setText("Total: -")
            self.final_gap_readout_lbl.setText("")
            self.start_delay_readout_lbl.setText("")
            self.safe_sc_lbl.setText("")
            self.start_delay_spin.blockSignals(True)
            self.start_delay_spin.setValue(0)
            self.start_delay_spin.blockSignals(False)
            self._clear_special_cases()
            return

        e = entries[0]
        self.cur_timing = e.timing
        self.cur_entry  = e

        if len(entries) == 1:
            self._set_entry_title(e.name)
        else:
            self._set_entry_title(f"{len(entries)} entries selected")

        self.timing_lbl.setText(f"{total_ticks(e.timing)}t")
        self.timing_field_lbl.setText(str(e.timing))
        self.total_stat_lbl.setText(timing_summary_text(e.timing))

        if e.name in self.mods:
            mod = self.mods[e.name]
            if len(mod) == 3:
                self.seq, self.anim_indices, self.cur_start_delay = mod
            else:
                self.seq, self.anim_indices = mod
                self.cur_start_delay = e.start_delay
        else:
            self.seq = e.as_step_list()
            self.anim_indices = e.get_anim_indices()
            self.cur_start_delay = e.start_delay

        self.start_delay_spin.blockSignals(True)
        self.start_delay_spin.setValue(self.cur_start_delay)
        self.start_delay_spin.blockSignals(False)
        self.start_delay_readout_lbl.setText(f"{self.cur_start_delay}t")

        self._refresh_seq()
        self._refresh_special_cases()
        self._update_safe_sc_label()

    def _update_safe_sc_label(self):
        e = self.cur_entry
        if e is None:
            self.safe_sc_lbl.setText(""); return
        mssc    = e.min_safe_sc
        cur_sc  = len(self.seq) if self.seq else e.sc
        if mssc > 1:
            warn = "⚠ " if cur_sc < mssc else ""
            self.safe_sc_lbl.setText(f"{warn}min sc = {mssc}  (current = {cur_sc})")
        else:
            self.safe_sc_lbl.setText("")

    def _clear_layout(self, layout):
        while layout.count():
            item = layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

    def _clear_special_cases(self):
        self.special_info_lbl.setText("No special cases detected.")
        self.anim_info_lbl.setText("")
        self._clear_layout(self.rescue_ids_layout)
        self._clear_layout(self.anim_inputs_layout)
        self.anim_inputs.clear()

    def _refresh_special_cases(self):
        """Update Rescue Section and animation controls for special entries."""
        e = self.cur_entry
        self._clear_special_cases()
        if e is None:
            return

        messages = []

        rescue = local_id_list_info(e)
        if rescue is not None:
            prefix_len, ids = rescue
            target_count = max(len(self.seq) - 1, 0)
            shown = [ids[i % len(ids)] for i in range(target_count)] if ids and target_count else ids
            messages.append("Identified this sequence as part of a Rescue Section.")
            for rid in shown:
                chip = QLabel(f"0x{rid:02X}")
                chip.setStyleSheet(
                    "QLabel{background:#3a2a1a;border:1px solid #8a6020;"
                    "color:#f5c987;padding:4px 8px;}"
                )
                self.rescue_ids_layout.addWidget(chip)

        if self.anim_indices:
            required_types = e.anim_indexed_step_types
            type_names = [step_display_name(required_types.get(idx, 0)) for idx in self.anim_indices]
            messages.append(f"Animation indices: requires {', '.join(type_names)}")
            self.anim_info_lbl.setText("Animation indices:")
            for i, idx in enumerate(self.anim_indices):
                spin = QSpinBox()
                spin.setRange(0, max(len(self.seq) - 1, 0))
                spin.setValue(idx)
                spin.setMaximumWidth(55)
                spin.valueChanged.connect(lambda val, i=i: self._on_anim_index_change(i, val))
                self.anim_inputs.append(spin)
                self.anim_inputs_layout.addWidget(spin)

        self.special_info_lbl.setText(" ".join(messages) if messages else "No special cases detected.")

    def _on_anim_index_change(self, slot, new_idx):
        """User changed an animation index spinbox."""
        if slot < len(self.anim_indices):
            self.anim_indices[slot] = new_idx

    def _on_start_delay_change(self, value):
        self.cur_start_delay = value
        if hasattr(self, "start_delay_readout_lbl"):
            self.start_delay_readout_lbl.setText(f"{value}t")

    def _refresh_seq(self):
        self.seq_w.set_seq(
            self.seq, self.cur_timing,
            self._remove_move,
            self._on_code_edit,
            self._on_gap_change
        )
        self.steps_stat_lbl.setText(f"Steps: {len(self.seq)}" if self.seq else "Steps: 0")
        self._update_implied()
        self._refresh_special_cases()
        self._update_safe_sc_label()

    def _update_implied(self):
        if not self.seq:
            self.implied_lbl.setText("Last gap: -")
            self.final_gap_readout_lbl.setText("")
            return
        stored = [s.gap for s in self.seq[:-1]]
        implied = implied_last_gap(self.cur_timing, stored)
        self.implied_lbl.setText(f"Last gap: {implied}t")
        self.final_gap_readout_lbl.setText(f"{implied}t")

    def _on_gap_change(self):
        self._update_implied()

    def _on_code_edit(self):
        # Code was mutated in-place; refresh labels and special-case preview.
        self._refresh_special_cases()
        self._update_safe_sc_label()

    def _remove_move(self, idx):
        new_sc = len(self.seq) - 1
        if not check_min_safe_sc(self, self.cur_entry, new_sc):
            return
        if idx < len(self.seq):
            self.seq.pop(idx)
            self._refresh_seq()

    def add_move(self, name):
        if name in GAME_TO_INTERNAL:
            code = GAME_TO_INTERNAL[name]
        elif name in INV:
            code = INV[name]
        else:
            return
        gap = default_gap(self.cur_timing, max(len(self.seq) + 1, 1))
        self.seq.append(Step(code, gap))
        self._refresh_seq()

    def add_raw_byte(self):
        """RAW... button: prompt for hex byte, append as a step."""
        text, ok = QInputDialog.getText(
            self, "Add raw byte step",
            "Enter raw byte value (hex, e.g. 0x41 or 41):"
        )
        if not ok or not text.strip():
            return
        try:
            val = int(text.strip(), 16)
            if not 0 <= val <= 255:
                raise ValueError
        except ValueError:
            QMessageBox.warning(self, "Invalid", f"'{text}' is not a valid byte (0x00-0xFF).")
            return
        gap = default_gap(self.cur_timing, max(len(self.seq) + 1, 1))
        self.seq.append(Step(val, gap))
        self._refresh_seq()

    def parse_text_input(self):
        """
        Tokens:
          MOVENAME          e.g. CHU  UP  DOWN:24
          RAW:0xNN          e.g. RAW:0x41  RAW:0x41:48
          0xNN              e.g. 0x41  0x41:24
          decimal int       e.g. 65   65:24
        """
        tokens  = self.seq_input.text().strip().split()
        new_seq = []
        n       = len(tokens)

        for t in tokens:
            parts    = t.split(":")
            move_tok = parts[0].upper()
            gap      = default_gap(self.cur_timing, max(n, 1))
            code     = None

            if move_tok == "RAW":
                if len(parts) >= 2:
                    try: code = int(parts[1], 16)
                    except ValueError: pass
                if len(parts) >= 3:
                    try: gap = int(parts[2])
                    except ValueError: pass

            elif move_tok.startswith("0X"):
                try: code = int(move_tok, 16)
                except ValueError: pass
                if len(parts) >= 2:
                    try: gap = int(parts[1])
                    except ValueError: pass

            elif move_tok in GAME_TO_INTERNAL:
                code = GAME_TO_INTERNAL[move_tok]
                if len(parts) >= 2:
                    try: gap = int(parts[1])
                    except ValueError: pass

            elif move_tok in INV:
                code = INV[move_tok]
                if len(parts) >= 2:
                    try: gap = int(parts[1])
                    except ValueError: pass

            elif move_tok.isdigit():
                code = int(move_tok)
                if len(parts) >= 2:
                    try: gap = int(parts[1])
                    except ValueError: pass

            if code is not None and 0 <= code <= 255:
                new_seq.append(Step(code, gap))

        if not check_min_safe_sc(self, self.cur_entry, len(new_seq)):
            return
        self.seq = new_seq
        self._refresh_seq()
        self.seq_input.clear()

    def clear_seq(self):
        if not check_min_safe_sc(self, self.cur_entry, 0):
            return
        self.seq = []
        self._refresh_seq()

    def apply_selected(self):
        items   = self.tree.selectedItems()
        entries = [i.data(0, Qt.ItemDataRole.UserRole) for i in items]
        entries = [e for e in entries if isinstance(e, Entry)]
        for e in entries:
            self.mods[e.name] = (list(self.seq), list(self.anim_indices), self.cur_start_delay)
        self.statusBar().showMessage(
            f"Applied to {len(entries)} entr{'y' if len(entries)==1 else 'ies'}", 3000
        )
