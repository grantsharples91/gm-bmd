defmodule GmBmdWeb.Gettext do
  @moduledoc """
  Gettext backend — staff read Arabic as well as English, so user-facing
  strings ship `en` + `ar` (plain PO files; no Kanta here).
  """
  use Gettext.Backend, otp_app: :gm_bmd
end
