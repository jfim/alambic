alias Alambic.Models.Model
alias Alambic.Repo

now = DateTime.utc_now() |> DateTime.truncate(:second)

for {version, stage, path} <- [
      {"extraction-dummy.1", :extraction, "scripts/extract"},
      {"cleaning-dummy.1", :cleaning, "scripts/clean"}
    ] do
  unless Repo.get(Model, version) do
    %Model{}
    |> Model.changeset(%{
      version: version,
      stage: stage,
      trained_at: now,
      artifact_path: path,
      training_sample_size: 0,
      status: :active
    })
    |> Repo.insert!()
  end
end
