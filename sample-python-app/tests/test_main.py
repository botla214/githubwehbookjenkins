from main import add, subtract, greet


def test_add():
    assert add(2, 3) == 5
    assert add(0, 0) == 0
    assert add(-1, 1) == 0


def test_subtract():
    assert subtract(10, 4) == 6
    assert subtract(5, 5) == 0
    assert subtract(0, 3) == -3


def test_greet():
    result = greet("World")
    assert "Hello" in result
    assert "World" in result
