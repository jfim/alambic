ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Alambic.Repo, :manual)
Mox.defmock(Alambic.ChamMock, for: Alambic.Cham)
