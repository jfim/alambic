defmodule Alambic.Repo do
  use Ecto.Repo,
    otp_app: :alambic,
    adapter: Ecto.Adapters.Postgres
end
