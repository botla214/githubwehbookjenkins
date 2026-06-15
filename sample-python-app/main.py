def add(a, b):
    return a + b


def subtract(a, b):
    return a - b


def greet(name):
    return f"Hello, {name}! Welcome to the RelayProxy CI demo."


if __name__ == "__main__":
    print(greet("DevOps Engineer"))
    print(f"2 + 3 = {add(2, 3)}")
    print(f"10 - 4 = {subtract(10, 4)}")
