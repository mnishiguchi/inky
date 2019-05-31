defmodule Inky do
  @moduledoc """
  Documentation for Inky.
  """

  @doc """
  Hello world.

  ## Examples

      iex> alias Inky
      iex> state = Inky.setup(nil, :phat, :red)
      iex> state = Enum.reduce(0..(state.height - 1), state, fn y, state ->Enum.reduce(0..(state.width - 1), state, fn x, state ->Inky.set_pixel(state, x, y, state.red)end)end)
      iex> Inky.show(state)

  """

  alias Circuits.SPI
  alias Circuits.GPIO

  alias Inky.InkyPhat
  alias Inky.InkyWhat
  alias Inky.LookupTables
  alias Inky.State

  @reset_pin 27
  @busy_pin 17
  @dc_pin 22

  # Note: unused
  @mosi_pin 10
  # Note: unused
  @sclk_pin 11

  @cs0_pin 0

  @spi_chunk_size 4096
  @spi_command 0
  @spi_data 1

  # Used in logo example
  # inkyphat and inkywhat classes
  # color constants: RED, BLACK, WHITE
  # dimension constants: WIDTH, HEIGHT
  # PIL: putpixel(value)
  # set_image
  # show

  # SPI bus options include:
  # * `mode`: This specifies the clock polarity and phase to use. (0)
  # * `bits_per_word`: bits per word on the bus (8)
  # * `speed_hz`: bus speed (1000000)
  # * `delay_us`: delay between transaction (10)

  def init(type, color)
      when type in [:phat, :what] and color in [:black, :red, :yellow] do
    color
    |> init_state()
    |> init_reset()
    |> init_type(type)
    |> setup_derived_values()
    |> soft_reset()
    |> busy_wait()
  end

  def set_pixel(state = %State{}, x, y, value) do
    if value in [state.white, state.black, state.red, state.yellow] do
      pixels = put_in(state.pixels, [{x, y}], value)
      %State{state | pixels: pixels}
    else
      state
    end
  end

  def show(state = %State{}) do
    # Not implemented: vertical flip
    # Not implemented: horizontal flip

    # Note: Rotation handled when converting to bytestring

    black_bytes = pixels_to_bytestring(state, state.black, 0, 1)
    red_bytes = pixels_to_bytestring(state, state.red, 1, 0)
    update(state, black_bytes, red_bytes)
  end

  def log_grid(state = %State{}) do
    grid =
      Enum.reduce(0..(state.height - 1), "", fn y, grid ->
        row =
          Enum.reduce(0..(state.width - 1), "", fn x, row ->
            color_value = Map.get(state.pixels, {x, y}, 0)

            row <>
              case color_value do
                0 -> "W"
                1 -> "B"
                2 -> "R"
              end
          end)

        grid <> row <> "\n"
      end)

    IO.puts(grid)
    state
  end

  defp init_state(luts_color) do
    %State{}
    |> init_pins()
    |> Map.put(:color, luts_color)
  end

  defp init_pins(state) do
    {:ok, dc_pid} = GPIO.open(@dc_pin, :output)
    {:ok, reset_pid} = GPIO.open(@reset_pin, :output)
    {:ok, busy_pid} = GPIO.open(@busy_pin, :input)
    {:ok, spi_pid} = SPI.open("spidev0." <> to_string(@cs0_pin), speed_hz: 488_000)

    # Use binary pattern matching to pull out the ADC counts (low 10 bits)
    # <<_::size(6), counts::size(10)>> = SPI.transfer(spi_pid, <<0x78, 0x00>>)
    %{
      state
      | dc_pid: dc_pid,
        reset_pid: reset_pid,
        busy_pid: busy_pid,
        spi_pid: spi_pid
    }
  end

  defp setup_derived_values(state) do
    # Little endian, unsigned short
    Map.put(state, :packed_height, [
      :binary.encode_unsigned(Enum.fetch!(state.resolution_data, 1), :little),
      <<0x00>>
    ])
  end

  defp busy_wait(state) do
    busy = GPIO.read(state.busy_pid)

    if busy in [1, true] do
      :timer.sleep(10)
      busy_wait(state)
    else
      state
    end
  end

  defp update(state, buffer_a, buffer_b) do
    state
    |> set_analog_block_control
    |> set_digital_block_control
    |> set_gate
    |> set_gate_driving_voltage
    |> dummy_line_period
    |> set_gate_line_width
    |> set_data_entry_mode
    |> power_on
    |> vcom_register
    |> set_border_color
    |> configure_if_yellow
    |> set_luts
    |> set_dimensions
    |> push_pixel_data_to_device(buffer_a, buffer_b)
    |> display_update_sequence
    |> trigger_display_update
    |> wait_before_sleep
    |> deep_sleep
  end

  def pixels_to_bytestring(state = %State{}, color_value, match, no_match) do
    rotation = state.rotation / 90

    {order, outer_from, outer_to, inner_from, inner_to} =
      case rotation do
        -1.0 -> {:x_outer, state.width - 1, 0, 0, state.height - 1}
        1.0 -> {:x_outer, 0, state.width - 1, state.height - 1, 0}
        -2.0 -> {:y_outer, state.width - 1, 0, state.height - 1, 0}
        _ -> {:y_outer, 0, state.height - 1, 0, state.width - 1}
      end

    for i <-
          Enum.flat_map(outer_from..outer_to, fn i ->
            Enum.map(inner_from..inner_to, fn j ->
              key =
                case order do
                  :x_outer -> {i, j}
                  :y_outer -> {j, i}
                end

              case state.pixels[key] do
                ^color_value -> match
                _ -> no_match
              end
            end)
          end),
        do: <<i::1>>,
        into: <<>>
  end

  defp init_reset(state) do
    GPIO.write(state.reset_pid, 0)
    :timer.sleep(100)
    GPIO.write(state.reset_pid, 1)
    :timer.sleep(100)
    state
  end

  defp init_type(state, type) do
    case type do
      :phat -> InkyPhat.update_state(state)
      :what -> InkyWhat.update_state(state)
    end
  end

  defp soft_reset(state = %State{}) do
    send_command(state, 0x12)
  end

  defp send_command(state = %State{}, command) when is_binary(command) do
    spi_write(state, @spi_command, command)
  end

  defp send_command(state = %State{}, command) do
    spi_write(state, @spi_command, <<command>>)
  end

  defp send_command(state = %State{}, command, data) do
    send_command(state, <<command>>)
    send_data(state, data)
  end

  defp send_data(state = %State{}, data) when is_integer(data) do
    spi_write(state, @spi_data, <<data>>)
  end

  defp send_data(state = %State{}, data) do
    spi_write(state, @spi_data, data)
  end

  defp spi_write(state = %State{}, data_or_command, values) when is_list(values) do
    GPIO.write(state.dc_pid, data_or_command)
    {:ok, <<_::binary>>} = SPI.transfer(state.spi_pid, :erlang.list_to_binary(values))
    state
  end

  defp spi_write(state = %State{}, data_or_command, values) when is_binary(values) do
    GPIO.write(state.dc_pid, data_or_command)
    {:ok, <<_::binary>>} = SPI.transfer(state.spi_pid, values)
    state
  end

  def try_get_state() do
    state = Inky.init(:phat, :red)

    Enum.reduce(0..(state.height - 1), state, fn y, state ->
      Enum.reduce(0..(state.width - 1), state, fn x, state ->
        Inky.set_pixel(state, x, y, state.red)
      end)
    end)
  end

  def try(state) do
    Inky.show(state)
  end

  # Device commands

  defp set_analog_block_control(state) do
    send_command(state, 0x74, 0x54)
  end

  defp set_digital_block_control(state) do
    send_command(state, 0x7E, 0x3B)
  end

  defp set_gate(state) do
    send_command(state, 0x01, :binary.list_to_bin(state.packed_height ++ [0x00]))
  end

  defp set_gate_driving_voltage(state) do
    send_command(state, 0x03, [0b10000, 0b0001])
  end

  defp dummy_line_period(state) do
    send_command(state, 0x3A, 0x07)
  end

  defp set_gate_line_width(state) do
    send_command(state, 0x3B, 0x04)
  end

  defp set_data_entry_mode(state) do
    # Data entry mode setting 0x03 = X/Y increment
    send_command(state, 0x11, 0x03)
  end

  defp power_on(state) do
    send_command(state, 0x04)
  end

  defp vcom_register(state) do
    # VCOM Register, 0x3c = -1.5v?
    send_command(state, 0x2C, 0x3C)
    send_command(state, 0x3C, 0x00)
  end

  defp set_border_color(state) do
    # Always black border
    send_command(state, 0x3C, 0x00)
  end

  defp configure_if_yellow(state) do
    # Set voltage of VSH and VSL on Yellow device
    if state.color == :yellow do
      send_command(state, 0x04, 0x07)
    else
      state
    end
  end

  defp set_luts(state) do
    send_command(state, 0x32, LookupTables.get_luts(state.color))
  end

  defp set_dimensions(state) do
    # Set RAM X Start/End
    send_command(state, 0x44, :binary.list_to_bin([0x00, trunc(state.columns / 8) - 1]))
    # Set RAM Y Start/End
    send_command(state, 0x45, :binary.list_to_bin([0x00, 0x00] ++ state.packed_height))
  end

  defp push_pixel_data_to_device(state, buffer_a, buffer_b) do
    # 0x24 == RAM B/W, 0x26 == RAM Red/Yellow/etc
    for data <- [{0x24, buffer_a}, {0x26, buffer_b}] do
      {cmd, buffer} = data

      # Set RAM X Pointer start
      send_command(state, 0x4E, 0x00)

      # Set RAM Y Pointer start
      send_command(state, 0x4F, <<0x00, 0x00>>)
      send_command(state, cmd, buffer)
    end

    state
  end

  defp display_update_sequence(state) do
    send_command(state, 0x22, 0xC7)
  end

  defp trigger_display_update(state) do
    send_command(state, 0x20)
  end

  defp wait_before_sleep(state) do
    :timer.sleep(50)
    busy_wait(state)
  end

  defp deep_sleep(state) do
    send_command(state, 0x10, 0x01)
  end
end
