Application.put_env(:ml_shared, :internal_secret, String.duplicate("t", 64))
ExUnit.start()
