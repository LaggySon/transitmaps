defmodule TransitmapsWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  They render the `ui-*` classes of the design guide (`DESIGN.md` at the root
  of the project; `assets/css/components.css` holds the rules), so templates
  keep using the core components and the look stays in one place. Tailwind is
  there for layout only.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: TransitmapsWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders a flash message as a notice: a state rail, a light tint, and a
  dismiss button. Info is a `progress` notice, an error a `failure` one.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info}>Agency added.</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      class="ui-notice tm-flash"
      data-status={if @kind == :error, do: "failure", else: "progress"}
      role={if @kind == :error, do: "alert", else: "status"}
      {@rest}
    >
      <span>
        <strong :if={@title}>{@title}.</strong>
        {msg}
      </span>
      <button
        type="button"
        class="ui-button ui-button--ghost ui-button--small ui-notice-end"
        aria-label={gettext("Dismiss")}
        phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      >
        ✕
      </button>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Retry</.button>
      <.button phx-click="go" variant="primary">Save changes</.button>
      <.button navigate={~p"/"}>All agencies</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary danger quiet ghost)
  attr :size, :string, values: ~w(compact small)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns =
      assign_new(assigns, :class, fn ->
        [
          "ui-button",
          assigns[:variant] && "ui-button--#{assigns[:variant]}",
          assigns[:size] && "ui-button--#{assigns[:size]}"
        ]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  The label sits above the field, a micro label. Values are monospaced.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "classes added to the input's own"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="ui-field">
      <label class="ui-field--inline ui-field">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={@class}
          {@rest}
        />{@label}
      </label>
      <.error :for={msg <- @errors} id={@id && "#{@id}-error"}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <label class="ui-field">
      <span :if={@label} class="ui-field-label">{@label}</span>
      <select
        id={@id}
        name={@name}
        class={["ui-select", @class]}
        multiple={@multiple}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && @id && "#{@id}-error"}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.error :for={msg <- @errors} id={@id && "#{@id}-error"}>{msg}</.error>
    </label>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <label class="ui-field">
      <span :if={@label} class="ui-field-label">{@label}</span>
      <textarea
        id={@id}
        name={@name}
        class={["ui-textarea", @class]}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && @id && "#{@id}-error"}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.error :for={msg <- @errors} id={@id && "#{@id}-error"}>{msg}</.error>
    </label>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <label class="ui-field">
      <span :if={@label} class="ui-field-label">{@label}</span>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={["ui-input", @class]}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && @id && "#{@id}-error"}
        {@rest}
      />
      <.error :for={msg <- @errors} id={@id && "#{@id}-error"}>{msg}</.error>
    </label>
    """
  end

  # Helper used by inputs to generate form errors
  attr :id, :string, default: nil
  slot :inner_block, required: true

  defp error(assigns) do
    ~H"""
    <span id={@id} class="ui-hint ui-hint--error">{render_slot(@inner_block)}</span>
    """
  end

  @doc """
  Renders a page header: the title on the left, a muted aside on the right.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class="ui-page-header">
      <div>
        <h1 class="ui-title">{render_slot(@inner_block)}</h1>
        <p :if={@subtitle != []} class="ui-muted">{render_slot(@subtitle)}</p>
      </div>
      <div :if={@actions != []} class="ui-title-aside">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table in its scroll container.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
    attr :class, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="ui-table-wrap">
      <table class="ui-table">
        <thead>
          <tr>
            <th :for={col <- @col} class={col[:class]}>{col[:label]}</th>
            <th :if={@action != []}>
              <span class="ui-sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={[col[:class], @row_click && "cursor-pointer"]}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []}>
              <div class="ui-button-group">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a key-value list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <dl class="ui-kv">
      <%= for item <- @item do %>
        <dt>{item.title}</dt>
        <dd>{render_slot(item)}</dd>
      <% end %>
    </dl>
    """
  end

  @doc """
  Renders a glyph. There is no icon library (DESIGN.md section 9): each name
  stands for one Unicode glyph, which takes the size and colour of the text
  around it. A glyph next to a word is decoration and is hidden from screen
  readers; a button holding only a glyph needs its own `aria-label`.

  ## Examples

      <.icon name="close" />
      <.icon name="refresh" />
  """
  attr :name, :string,
    required: true,
    values: ~w(close up down swap refresh edit external collapsed expanded done)

  attr :class, :any, default: nil

  def icon(assigns) do
    ~H"""
    <span class={@class} aria-hidden="true">{glyph(@name)}</span>
    """
  end

  defp glyph("close"), do: "✕"
  defp glyph("up"), do: "↑"
  defp glyph("down"), do: "↓"
  defp glyph("swap"), do: "⇄"
  defp glyph("refresh"), do: "↻"
  defp glyph("edit"), do: "✎"
  defp glyph("external"), do: "↗"
  defp glyph("collapsed"), do: "▸"
  defp glyph("expanded"), do: "▾"
  defp glyph("done"), do: "✓"

  ## JS Commands

  # Nothing moves or fades in (DESIGN.md section 8): elements just appear.
  def show(js \\ %JS{}, selector) do
    JS.show(js, to: selector)
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js, to: selector)
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(TransitmapsWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(TransitmapsWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
