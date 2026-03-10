ExUnit.start()

"test_support/**/*.{ex,exs}"
|> Path.wildcard()
|> Enum.each(&Code.require_file/1)
