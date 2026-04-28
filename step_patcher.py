#!/usr/bin/env python3
import sys

from PyQt6.QtWidgets import QApplication

from sc5_ui import App, STYLESHEET


def main():
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    app.setStyleSheet(STYLESHEET)
    w = App()
    w.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
