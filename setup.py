from setuptools import setup

setup(
    name="orcha",
    version="0.1.0",
    py_modules=["orchestrator", "scan_and_refactor", "propagate_rename"],
    install_requires=[
        "langgraph>=0.0.10",
        "typing-extensions>=4.0.0",
    ],
    entry_points={
        "console_scripts": [
            "orcha=orchestrator:main",
            "orcha-scan=scan_and_refactor:main",
            "orcha-propagate=propagate_rename:main",
        ],
    },
    python_requires=">=3.10",
)
