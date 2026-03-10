defmodule NervesWifibroadcast.Radio.Channel do
  @moduledoc false

  @type width_spec ::
          {:ofdm, 5}
          | {:ofdm, 10}
          | :ht20
          | {:ht40, :plus | :minus}
          | {:vht, 80}
          | {:vht, 160}

  @spec normalize_channel!(String.t() | pos_integer()) :: pos_integer()
  def normalize_channel!(channel), do: normalize_positive_integer!(channel, "channel")

  @spec normalize_frequency!(String.t() | pos_integer()) :: pos_integer()
  def normalize_frequency!(frequency_mhz),
    do: normalize_positive_integer!(frequency_mhz, "frequency")

  @spec normalize_width!(String.t() | pos_integer()) :: width_spec()
  def normalize_width!(5), do: {:ofdm, 5}
  def normalize_width!("5"), do: {:ofdm, 5}
  def normalize_width!("5MHz"), do: {:ofdm, 5}
  def normalize_width!(10), do: {:ofdm, 10}
  def normalize_width!("10"), do: {:ofdm, 10}
  def normalize_width!("10MHz"), do: {:ofdm, 10}
  def normalize_width!(20), do: :ht20
  def normalize_width!("20"), do: :ht20
  def normalize_width!("HT20"), do: :ht20
  def normalize_width!(40), do: {:ht40, :plus}
  def normalize_width!("40"), do: {:ht40, :plus}
  def normalize_width!("HT40+"), do: {:ht40, :plus}
  def normalize_width!("HT40-"), do: {:ht40, :minus}
  def normalize_width!(80), do: {:vht, 80}
  def normalize_width!("80"), do: {:vht, 80}
  def normalize_width!("80MHz"), do: {:vht, 80}
  def normalize_width!(160), do: {:vht, 160}
  def normalize_width!("160"), do: {:vht, 160}
  def normalize_width!("160MHz"), do: {:vht, 160}

  def normalize_width!(width) do
    raise ArgumentError,
          "expected width to be one of 5, 10, 20, 40, 80, 160 or an equivalent width token, got: #{inspect(width)}"
  end

  @spec channel_to_frequency!(pos_integer()) :: pos_integer()
  def channel_to_frequency!(14), do: 2484

  def channel_to_frequency!(channel) when is_integer(channel) and channel >= 1 and channel <= 13,
    do: 2407 + channel * 5

  def channel_to_frequency!(channel)
      when is_integer(channel) and channel >= 182 and channel <= 196,
      do: 4000 + channel * 5

  def channel_to_frequency!(channel)
      when is_integer(channel) and channel >= 32 and channel <= 177,
      do: 5000 + channel * 5

  def channel_to_frequency!(channel) do
    raise ArgumentError, "unsupported wifi channel #{inspect(channel)}"
  end

  @spec center_frequency1!(pos_integer(), width_spec()) :: pos_integer()
  def center_frequency1!(frequency_mhz, {:ht40, :plus}), do: frequency_mhz + 10
  def center_frequency1!(frequency_mhz, {:ht40, :minus}), do: frequency_mhz - 10

  def center_frequency1!(frequency_mhz, {:vht, 80}) do
    case frequency_mhz do
      freq when freq >= 5180 and freq <= 5240 ->
        5210

      freq when freq >= 5260 and freq <= 5320 ->
        5290

      freq when freq >= 5500 and freq <= 5560 ->
        5530

      freq when freq >= 5580 and freq <= 5640 ->
        5610

      freq when freq >= 5660 and freq <= 5720 ->
        5690

      freq when freq >= 5745 and freq <= 5805 ->
        5775

      freq when freq >= 5825 and freq <= 5885 ->
        5855

      _other ->
        raise ArgumentError,
              "unable to derive 80 MHz center frequency for #{inspect(frequency_mhz)}"
    end
  end

  def center_frequency1!(frequency_mhz, {:vht, 160}) do
    case frequency_mhz do
      freq when freq >= 5180 and freq <= 5320 ->
        5250

      freq when freq >= 5500 and freq <= 5640 ->
        5570

      freq when freq >= 5745 and freq <= 5885 ->
        5815

      _other ->
        raise ArgumentError,
              "unable to derive 160 MHz center frequency for #{inspect(frequency_mhz)}"
    end
  end

  def center_frequency1!(frequency_mhz, width) do
    raise ArgumentError,
          "center frequency is not used for #{inspect(width)} at #{inspect(frequency_mhz)} MHz"
  end

  defp normalize_positive_integer!(value, _name) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer!(value, name) when is_binary(value) and byte_size(value) > 0 do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> raise ArgumentError, "expected #{name} to be numeric, got: #{inspect(value)}"
    end
  end

  defp normalize_positive_integer!(value, name) do
    raise ArgumentError,
          "expected #{name} to be a positive integer or numeric string, got: #{inspect(value)}"
  end
end
