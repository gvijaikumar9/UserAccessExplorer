<#
    User Access Explorer - a desktop window over the UserAccessExplorer module.

    Run:
        pwsh -File .\Show-UserAccessExplorer.ps1
    or right-click > Run with PowerShell 7.

    WPF needs STA and PS7 is MTA by default, so the whole GUI runs in an STA
    runspace. The scan runs in a background runspace so the window stays
    responsive; rows appear live and progress is read from the scan's own
    Write-Progress stream (site N of M).

    Flow:
      - Gear (top right) -> Client ID + Tenant admin URL -> Connect (once).
      - Type a name or email in the User box; it searches as you type. Pick one.
      - Choose scope (Whole tenant / One site), then Scan. Stop cancels.
#>

$moduleManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'UserAccessExplorer.psd1'

$guiScript = {
    param($ModulePath)

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    Import-Module $ModulePath -Force
    $script:ModulePath = $ModulePath

    # Real typed node for the tree. WPF's HierarchicalDataTemplate binds a
    # nested Children collection reliably on a CLR class, but NOT on a
    # PSCustomObject note-property (simple props bind, collections silently do
    # not) - which is why the tree showed only the root.
    class UaeNode {
        [string]$Name = ''
        [string]$Kind = ''
        [string]$Glyph = ''
        [string]$Url = ''
        [string]$PermUrl = ''
        [string]$RiskText = ''
        [object]$RiskBg
        [object]$RiskFg
        [string]$RiskVisibility = 'Collapsed'
        [string]$GrantPath = ''
        [string]$Effective = ''
        [bool]$IsExpanded = $true
        [bool]$IsUnexpected = $false
        [bool]$FromScan = $false
        [int]$TotalCount = -1
        [string]$CountLabel = ''
        [System.Collections.ObjectModel.ObservableCollection[object]]$Children = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    }

    $script:ScanBlock = {
        param($ModulePath, $User, $ClientId, $Url, $Mode, $UserB)
        Import-Module $ModulePath -Force
        # run the same scope for one user; tag each row so the GUI can tell A from B
        $runFor = {
            param($u, $tag, $cid, $url, $scope)
            $common = @{ User = $u; ClientId = $cid; Interactive = $true }
            $rows = switch ($scope) {
                'Tenant' { Get-UserAccess @common -TenantWide -TenantAdminUrl $url }
                # Deep = one site, all the way down (subsites, lists, items) plus the
                # sharing links a plain permission check can't see. Slow by nature.
                'Deep'   { Get-UserAccess @common -SiteUrl $url -Deep -IncludeItems }
                default  { Get-UserAccess @common -SiteUrl $url }
            }
            foreach ($r in $rows) { if ($tag) { $r | Add-Member -NotePropertyName CmpUser -NotePropertyValue $tag -Force }; $r }
        }
        if ($UserB) {
            & $runFor $User  'A' $ClientId $Url $Mode
            & $runFor $UserB 'B' $ClientId $Url $Mode
        } else {
            & $runFor $User $null $ClientId $Url $Mode
        }
    }

    # Enumerate the tenant's content sites so the One-site picker is a selection,
    # not a URL to type. Same exclusions the module uses (redirect stubs, the
    # OneDrive/MySite host). Runs in the background - a big tenant is slow.
    $script:SiteEnumBlock = {
        param($ModulePath, $ClientId, $Admin)
        Import-Module $ModulePath -Force
        Connect-PnPOnline -Url $Admin -ClientId $ClientId -Interactive
        Get-PnPTenantSite | Where-Object {
            $_.Template -notlike 'REDIRECT*' -and $_.Template -notlike 'SPSMSITEHOST*' -and $_.Url -notlike '*-my.sharepoint.com*'
        } | ForEach-Object { [pscustomobject]@{ Title = "$($_.Title)"; Url = "$($_.Url)" } }
    }

    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="User Access Explorer" Height="760" Width="820"
        WindowStartupLocation="CenterScreen" MinWidth="720" MinHeight="600"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13"
        Background="{DynamicResource Canvas}">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent"      Color="#0F6CBD"/>
    <SolidColorBrush x:Key="AccentHover" Color="#115EA3"/>
    <SolidColorBrush x:Key="AccentPress" Color="#0C3B5E"/>
    <SolidColorBrush x:Key="Ink"         Color="#242424"/>
    <SolidColorBrush x:Key="Subtle"      Color="#707882"/>
    <SolidColorBrush x:Key="Line"        Color="#E6E8EB"/>
    <SolidColorBrush x:Key="FieldBorder" Color="#C9CDD2"/>
    <SolidColorBrush x:Key="Surface"     Color="#FFFFFF"/>
    <SolidColorBrush x:Key="TileBg"      Color="#F7F8FA"/>
    <SolidColorBrush x:Key="RiskBg"      Color="#FCE7EA"/>
    <SolidColorBrush x:Key="RiskFg"      Color="#B10E1C"/>
    <SolidColorBrush x:Key="Canvas"       Color="#EEF0F3"/>
    <SolidColorBrush x:Key="RailBg"       Color="#F4F6F8"/>
    <SolidColorBrush x:Key="RowBg"        Color="#FFFFFF"/>
    <SolidColorBrush x:Key="SelBg"        Color="#E9F1FB"/>
    <SolidColorBrush x:Key="OversharedRow" Color="#FDF3F2"/>
    <SolidColorBrush x:Key="IconBlue"     Color="#E7F0FB"/>
    <SolidColorBrush x:Key="IconRed"      Color="#FBE3E6"/>
    <SolidColorBrush x:Key="IconGreen"    Color="#E7F3EC"/>
    <SolidColorBrush x:Key="IconPurple"   Color="#EFE9F5"/>
    <SolidColorBrush x:Key="TileOversharedBg" Color="#FCE7EA"/>
    <SolidColorBrush x:Key="TileDanger"       Color="#B10E1C"/>
    <SolidColorBrush x:Key="FieldDisabled"    Color="#F2F3F5"/>
    <SolidColorBrush x:Key="BtnDisabledBg"    Color="#E4E6E9"/>
    <SolidColorBrush x:Key="BtnDisabledFg"    Color="#A6ABB2"/>
    <SolidColorBrush x:Key="OversharedPillBg" Color="#FCE7EA"/>
    <SolidColorBrush x:Key="OversharedPillFg" Color="#B10E1C"/>
    <SolidColorBrush x:Key="GrantedPillBg"    Color="#EAF1E7"/>
    <SolidColorBrush x:Key="GrantedPillFg"    Color="#107C41"/>
    <SolidColorBrush x:Key="Hover"            Color="#EDEFF2"/>
    <SolidColorBrush x:Key="NavActive"        Color="#E7F0FB"/>

    <!-- Fixed glyph colour (not a themed brush): MDL2 glyph runs do NOT reliably
         repaint when their DynamicResource foreground is swapped on a theme change,
         so they blank out in dark mode. #8A9099 reads on both light and dark. -->
    <Style x:Key="Glyph" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="Foreground" Value="#8A9099"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="Field" TargetType="TextBox">
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="10,0,10,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="BorderBrush" Value="{DynamicResource FieldBorder}"/>
      <Setter Property="Background" Value="{DynamicResource Surface}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border CornerRadius="6" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Background" Value="{DynamicResource FieldDisabled}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- themed dropdown item (only applied to the FieldCombo boxes, so the
         still-light connect popup keeps its native items) -->
    <Style x:Key="ComboItem" TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="Padding" Value="10,6,10,6"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="b" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}" CornerRadius="4">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource SelBg}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- editable ComboBox, fully themed (the default template hardcodes a white
         edit field that ignores Background - the dark-mode offender) -->
    <Style x:Key="FieldCombo" TargetType="ComboBox">
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="8,0,4,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="BorderBrush" Value="{DynamicResource FieldBorder}"/>
      <Setter Property="Background" Value="{DynamicResource Surface}"/>
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="ItemContainerStyle" Value="{StaticResource ComboItem}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="toggle" Focusable="False" ClickMode="Press" Background="{TemplateBinding Background}"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border CornerRadius="6" Background="{TemplateBinding Background}"
                            BorderBrush="{Binding BorderBrush, RelativeSource={RelativeSource AncestorType=ComboBox}}" BorderThickness="1">
                      <TextBlock Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="9"
                                 Foreground="#8A9099" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0"/>
                    </Border>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter x:Name="cp" Margin="10,0,28,0" VerticalAlignment="Center" IsHitTestVisible="False"
                                Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <TextBox x:Name="PART_EditableTextBox" Margin="7,0,28,0" VerticalContentAlignment="Center" Visibility="Hidden"
                       Background="Transparent" Foreground="{DynamicResource Ink}" CaretBrush="{DynamicResource Ink}" BorderThickness="0"/>
              <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                <Border Background="{DynamicResource Surface}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="6"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="320" Margin="0,2,0,0">
                  <ScrollViewer><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEditable" Value="True">
                <Setter TargetName="PART_EditableTextBox" Property="Visibility" Value="Visible"/>
                <Setter TargetName="cp" Property="Visibility" Value="Collapsed"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="toggle" Property="Background" Value="{DynamicResource FieldDisabled}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="18,0,18,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{StaticResource AccentHover}"/></Trigger>
              <Trigger Property="IsPressed"  Value="True"><Setter TargetName="b" Property="Background" Value="{StaticResource AccentPress}"/></Trigger>
              <Trigger Property="IsEnabled"  Value="False">
                <Setter TargetName="b" Property="Background" Value="{DynamicResource BtnDisabledBg}"/>
                <Setter Property="Foreground" Value="{DynamicResource BtnDisabledFg}"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Secondary" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="Background" Value="{DynamicResource Surface}"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="14,0,14,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6"
                    BorderBrush="{DynamicResource FieldBorder}" BorderThickness="1" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Hover}"/></Trigger>
              <Trigger Property="IsEnabled"  Value="False">
                <Setter Property="Foreground" Value="{DynamicResource BtnDisabledFg}"/>
                <Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Line}"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- icon-only button (gear, overflow) -->
    <Style x:Key="IconButton" TargetType="Button">
      <Setter Property="Width" Value="34"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="#8A9099"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent" CornerRadius="6">
              <TextBlock Text="{TemplateBinding Content}" FontFamily="Segoe MDL2 Assets" FontSize="16"
                         Foreground="{TemplateBinding Foreground}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Hover}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- pill toggle (tree view) -->
    <Style x:Key="PillToggle" TargetType="ToggleButton">
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="14,0,14,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="b" Background="{DynamicResource Surface}" CornerRadius="6"
                    BorderBrush="{DynamicResource FieldBorder}" BorderThickness="1" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Hover}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="{StaticResource RiskBg}"/>
                <Setter TargetName="b" Property="BorderBrush" Value="#F1B9C0"/>
                <Setter Property="Foreground" Value="{StaticResource RiskFg}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="TileLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource Subtle}"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <Style x:Key="TileValue" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="FontSize" Value="24"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,2,0,0"/>
    </Style>

    <!-- open-permissions link: a small key-icon button on each object row/node
         that jumps to that object's advanced-permissions page in SharePoint -->
    <Style x:Key="OpenPermBtn" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="ToolTip" Value="Open this object's permissions page in SharePoint"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent" CornerRadius="5" Padding="5,3,5,3">
              <TextBlock Text="&#xE71B;" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="{StaticResource Accent}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource NavActive}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <!-- synthesised container nodes (no scanned object) carry no PermUrl -->
        <DataTrigger Binding="{Binding PermUrl}" Value=""><Setter Property="Visibility" Value="Collapsed"/></DataTrigger>
      </Style.Triggers>
    </Style>

    <!-- left-rail navigation item (radio = one active view at a time) -->
    <Style x:Key="NavItem" TargetType="RadioButton">
      <Setter Property="Height" Value="40"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Margin" Value="0,2,0,2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" CornerRadius="8" Background="Transparent" Padding="12,0,12,0" ToolTip="{TemplateBinding Content}">
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock x:Name="ico" Text="{TemplateBinding Tag}" FontFamily="Segoe MDL2 Assets" FontSize="15"
                           Foreground="#8A9099" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <ContentPresenter VerticalAlignment="Center" Visibility="{DynamicResource NavTextVis}"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Hover}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="{DynamicResource NavActive}"/>
                <Setter TargetName="ico" Property="Foreground" Value="#4C9DF0"/>
                <Setter Property="Foreground" Value="#4C9DF0"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- rail item that is an action, not a view (Settings opens the popup) -->
    <Style x:Key="NavItemBtn" TargetType="Button">
      <Setter Property="Height" Value="40"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="8" Background="Transparent" Padding="12,0,12,0" ToolTip="{TemplateBinding Content}">
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock Text="{TemplateBinding Tag}" FontFamily="Segoe MDL2 Assets" FontSize="15"
                           Foreground="#8A9099" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <ContentPresenter VerticalAlignment="Center" Visibility="{DynamicResource NavTextVis}"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Hover}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- SharePoint brand mark, drawn as vector (Segoe MDL2 has no SharePoint
         glyph). Brand-teal disc with the white "S" swoosh - reads as SharePoint
         without embedding Microsoft's trademarked logo image. -->
    <DrawingImage x:Key="SharePointLogo">
      <DrawingImage.Drawing>
        <DrawingGroup>
          <GeometryDrawing Brush="#036C70">
            <GeometryDrawing.Geometry>
              <EllipseGeometry Center="16,16" RadiusX="15" RadiusY="15"/>
            </GeometryDrawing.Geometry>
          </GeometryDrawing>
          <GeometryDrawing>
            <GeometryDrawing.Pen>
              <Pen Brush="White" Thickness="2.7" StartLineCap="Round" EndLineCap="Round"/>
            </GeometryDrawing.Pen>
            <GeometryDrawing.Geometry>
              <PathGeometry Figures="M20.5,11 C20.5,8.3 11.5,8.3 11.5,12 C11.5,15.2 20.5,15.4 20.5,19 C20.5,22.7 11.5,22.7 11.5,20"/>
            </GeometryDrawing.Geometry>
          </GeometryDrawing>
        </DrawingGroup>
      </DrawingImage.Drawing>
    </DrawingImage>

    <!-- transparent drag-handle on each column-header edge. The custom header
         template replaces the default one, which is where WPF normally puts the
         PART_*HeaderGripper thumbs that let you resize columns - so we add them
         back by name and the DataGrid wires them up automatically. -->
    <Style x:Key="ColHeaderGripper" TargetType="Thumb">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Cursor" Value="SizeWE"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border Background="{TemplateBinding Background}"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <!-- APP SHELL: left rail + content -->
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="Auto"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- LEFT RAIL -->
    <Border x:Name="RailBorder" Grid.Column="0" Width="208" Background="{DynamicResource RailBg}" BorderBrush="{DynamicResource Line}" BorderThickness="0,0,1,0">
      <DockPanel x:Name="RailDock" Margin="14,16,14,16">
        <StackPanel DockPanel.Dock="Top" Margin="0,0,0,20">
          <Button x:Name="RailToggle" Style="{StaticResource IconButton}" Content="&#xE700;" HorizontalAlignment="Left" ToolTip="Collapse / expand the sidebar"/>
          <TextBlock Text="User Access Explorer" FontWeight="SemiBold" FontSize="14" Foreground="{DynamicResource Ink}"
                     TextWrapping="Wrap" Width="150" Margin="2,10,0,0" Visibility="{DynamicResource NavTextVis}"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom">
          <Border Height="1" Background="{DynamicResource Line}" Margin="0,0,0,10"/>
          <Button x:Name="ThemeToggle" Style="{StaticResource NavItemBtn}" Content="Dark mode" Tag="&#xE708;"/>
          <Button x:Name="VersionButton" Cursor="Hand" Margin="0,2,0,0" HorizontalAlignment="Left" ToolTip="About &#38; check for updates">
            <Button.Template>
              <ControlTemplate TargetType="Button">
                <Border x:Name="vb" Background="Transparent" CornerRadius="8" Padding="12,6,12,6">
                  <ContentPresenter/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="vb" Property="Background" Value="{DynamicResource Hover}"/></Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Button.Template>
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE946;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="#8A9099" VerticalAlignment="Center" Margin="0,0,7,0"/>
              <TextBlock x:Name="VersionText" Text="v0.0.0" FontSize="11.5" Foreground="{DynamicResource Subtle}" VerticalAlignment="Center" Visibility="{DynamicResource NavTextVis}"/>
              <Border x:Name="UpdateBadge" Background="{DynamicResource Accent}" CornerRadius="7" Padding="6,0,6,1" Margin="8,0,0,0" VerticalAlignment="Center" Visibility="Collapsed">
                <TextBlock Text="Update" FontSize="10" FontWeight="SemiBold" Foreground="White"/>
              </Border>
            </StackPanel>
          </Button>
        </StackPanel>
        <StackPanel DockPanel.Dock="Top">
          <TextBlock Text="DISCOVER" FontSize="10.5" FontWeight="SemiBold" Foreground="#9AA0A6" Margin="12,0,0,6" Visibility="{DynamicResource NavTextVis}"/>
          <RadioButton x:Name="NavScan"  Style="{StaticResource NavItem}" Content="Scan"        Tag="&#xE721;" IsChecked="True"/>
          <RadioButton x:Name="NavSaved" Style="{StaticResource NavItem}" Content="Scan history" Tag="&#xE81C;"/>
          <RadioButton x:Name="NavReports" Style="{StaticResource NavItem}" Content="Reports" Tag="&#xE8A5;"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- CONTENT -->
    <Grid Grid.Column="1">

  <!-- SCAN VIEW: one white card on a light canvas -->
  <Border x:Name="ScanView" Margin="14" Background="{DynamicResource Surface}" CornerRadius="10"
          BorderBrush="{DynamicResource Line}" BorderThickness="1">
    <Grid Margin="0">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>  <!-- header -->
        <RowDefinition Height="Auto"/>  <!-- controls -->
        <RowDefinition Height="Auto"/>  <!-- tiles -->
        <RowDefinition Height="Auto"/>  <!-- toolbar -->
        <RowDefinition Height="Auto"/>  <!-- list header -->
        <RowDefinition Height="*"/>     <!-- list -->
        <RowDefinition Height="Auto"/>  <!-- footer -->
      </Grid.RowDefinitions>

      <!-- HEADER -->
      <Grid Grid.Row="0" Margin="20,16,14,14">
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="Scan" FontSize="18" FontWeight="SemiBold" Foreground="{DynamicResource Ink}"/>
          <TextBlock Text="What a user can reach, and how they got there" FontSize="12.5" Foreground="{DynamicResource Subtle}" Margin="0,1,0,0"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Border x:Name="TenantChip" CornerRadius="12" Background="{DynamicResource TileBg}" Padding="10,4,12,4" VerticalAlignment="Center">
            <StackPanel Orientation="Horizontal">
              <TextBlock x:Name="TenantChipIcon" Style="{StaticResource Glyph}" Text="&#xE711;" FontSize="12" Foreground="{DynamicResource Subtle}" Margin="0,0,6,0"/>
              <TextBlock x:Name="TenantChipText" Text="Not connected" FontSize="12" Foreground="{DynamicResource Subtle}" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>
          <Button x:Name="SettingsButton" Style="{StaticResource IconButton}" Content="&#xE713;" Margin="8,0,0,0" ToolTip="Connection settings"/>
        </StackPanel>
      </Grid>

      <Border Grid.Row="0" Height="1" Background="{DynamicResource Line}" VerticalAlignment="Bottom"/>

      <!-- CONTROLS -->
      <Grid Grid.Row="1" Margin="20,16,20,4">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel Grid.Row="0" Grid.Column="0" Margin="0,0,12,0">
          <DockPanel Margin="0,0,0,4">
            <TextBlock Text="User" Style="{StaticResource TileLabel}"/>
            <TextBlock DockPanel.Dock="Right" HorizontalAlignment="Right" FontSize="11.5">
              <Hyperlink x:Name="CompareLink" Foreground="{DynamicResource Accent}" TextDecorations="None">Compare two users</Hyperlink>
            </TextBlock>
          </DockPanel>
          <Grid>
            <ComboBox x:Name="UserCombo" Style="{StaticResource FieldCombo}" IsEnabled="False"
                      IsEditable="True" IsTextSearchEnabled="False" StaysOpenOnEdit="True" DisplayMemberPath="Display"/>
            <TextBlock x:Name="UserPlaceholder" Text="Type a name or email - at least 2 letters" Margin="12,0,0,0"
                       VerticalAlignment="Center" Foreground="#9AA0A6" IsHitTestVisible="False"/>
          </Grid>
        </StackPanel>

        <StackPanel Grid.Row="0" Grid.Column="1" Margin="0,0,12,0">
          <TextBlock Text="Scope" Style="{StaticResource TileLabel}" Margin="0,0,0,4"/>
          <ComboBox x:Name="ScopeCombo" Style="{StaticResource FieldCombo}" Width="175">
            <ComboBoxItem Content="Whole tenant" IsSelected="True"/>
            <ComboBoxItem Content="One site"/>
            <ComboBoxItem Content="One site (deep)"/>
          </ComboBox>
        </StackPanel>

        <Button x:Name="ScanButton" Grid.Row="0" Grid.Column="2" Style="{StaticResource Primary}"
                Content="Scan" Width="92" VerticalAlignment="Bottom" IsEnabled="False"/>

        <!-- site row, only for One site: pick from the populated list or search -->
        <Grid x:Name="SiteRow" Grid.Row="1" Grid.ColumnSpan="3" Margin="0,10,0,0" Visibility="Collapsed">
          <ComboBox x:Name="SiteCombo" Style="{StaticResource FieldCombo}"
                    IsEditable="True" IsTextSearchEnabled="True" StaysOpenOnEdit="True" DisplayMemberPath="Display"/>
          <TextBlock x:Name="SitePlaceholder" Text="Select a site, or type to search" Margin="12,0,0,0"
                     VerticalAlignment="Center" Foreground="#9AA0A6" IsHitTestVisible="False"/>
        </Grid>

        <!-- second user, only in Compare mode -->
        <StackPanel x:Name="UserRowB" Grid.Row="2" Grid.ColumnSpan="3" Margin="0,10,0,0" Visibility="Collapsed">
          <TextBlock Text="Second user (to compare with)" Style="{StaticResource TileLabel}" Margin="0,0,0,4"/>
          <Grid>
            <ComboBox x:Name="UserComboB" Style="{StaticResource FieldCombo}"
                      IsEditable="True" IsTextSearchEnabled="False" StaysOpenOnEdit="True" DisplayMemberPath="Display"/>
            <TextBlock x:Name="UserPlaceholderB" Text="Type a name or email - at least 2 letters" Margin="12,0,0,0"
                       VerticalAlignment="Center" Foreground="#9AA0A6" IsHitTestVisible="False"/>
          </Grid>
        </StackPanel>
      </Grid>

      <!-- STAT TILES -->
      <UniformGrid Grid.Row="2" Rows="1" Columns="4" Margin="20,14,20,6">
        <Border Background="{DynamicResource TileBg}" CornerRadius="8" Margin="0,0,6,0" Padding="14,10,14,10">
          <StackPanel Orientation="Horizontal">
            <Border Width="38" Height="38" CornerRadius="8" Background="{DynamicResource IconBlue}" VerticalAlignment="Center" Margin="0,0,12,0">
              <TextBlock Style="{StaticResource Glyph}" Text="&#xE71B;" FontSize="17" Foreground="#4C9DF0" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel VerticalAlignment="Center"><TextBlock x:Name="TileRoutesLabel" Text="Routes found" Style="{StaticResource TileLabel}"/><TextBlock x:Name="TileRoutes" Text="0" Style="{StaticResource TileValue}"/></StackPanel>
          </StackPanel>
        </Border>
        <Border x:Name="TileUnexpectedCard" Background="{DynamicResource TileBg}" CornerRadius="8" Margin="6,0,6,0" Padding="14,10,14,10">
          <StackPanel Orientation="Horizontal">
            <Border Width="38" Height="38" CornerRadius="8" Background="{DynamicResource IconRed}" VerticalAlignment="Center" Margin="0,0,12,0">
              <TextBlock Style="{StaticResource Glyph}" Text="&#xE7BA;" FontSize="17" Foreground="#E85D6B" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel VerticalAlignment="Center"><TextBlock x:Name="TileUnexpLabel" Text="Overshared" Style="{StaticResource TileLabel}"/><TextBlock x:Name="TileUnexpected" Text="0" Style="{StaticResource TileValue}"/></StackPanel>
          </StackPanel>
        </Border>
        <Border Background="{DynamicResource TileBg}" CornerRadius="8" Margin="6,0,6,0" Padding="14,10,14,10">
          <StackPanel Orientation="Horizontal">
            <Border Width="38" Height="38" CornerRadius="8" Background="{DynamicResource IconGreen}" VerticalAlignment="Center" Margin="0,0,12,0">
              <TextBlock Style="{StaticResource Glyph}" Text="&#xE73E;" FontSize="17" Foreground="#2F9E5E" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel VerticalAlignment="Center"><TextBlock x:Name="TileSitesLabel" Text="Sites reached" Style="{StaticResource TileLabel}"/><TextBlock x:Name="TileSites" Text="0" Style="{StaticResource TileValue}"/></StackPanel>
          </StackPanel>
        </Border>
        <Border Background="{DynamicResource TileBg}" CornerRadius="8" Margin="6,0,0,0" Padding="14,10,14,10">
          <StackPanel Orientation="Horizontal">
            <Border Width="38" Height="38" CornerRadius="8" Background="{DynamicResource IconPurple}" VerticalAlignment="Center" Margin="0,0,12,0">
              <TextBlock Style="{StaticResource Glyph}" Text="&#xE72E;" FontSize="17" Foreground="#9B6FD4" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel VerticalAlignment="Center"><TextBlock x:Name="TileAccessLabel" Text="Highest access" Style="{StaticResource TileLabel}"/><TextBlock x:Name="TileAccess" Text="-" Style="{StaticResource TileValue}"/></StackPanel>
          </StackPanel>
        </Border>
      </UniformGrid>

      <!-- TOOLBAR -->
      <Grid Grid.Row="3" Margin="20,8,20,10">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Grid Grid.Column="0" Margin="0,0,10,0">
          <TextBox x:Name="FilterBox" Style="{StaticResource Field}"/>
          <TextBlock x:Name="FilterPlaceholder" Text="Filter sites or groups" Margin="12,0,0,0"
                     VerticalAlignment="Center" Foreground="#9AA0A6" IsHitTestVisible="False"/>
        </Grid>
        <ToggleButton x:Name="OversharedToggle" Grid.Column="1" Style="{StaticResource PillToggle}" Margin="0,0,10,0"
                      ToolTip="Show only the routes the user was never explicitly given">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE7BA;" FontFamily="Segoe MDL2 Assets" FontSize="12" Margin="0,0,6,0" VerticalAlignment="Center"/>
            <TextBlock Text="Overshared only" VerticalAlignment="Center"/>
          </StackPanel>
        </ToggleButton>
        <ToggleButton x:Name="ViewToggle" Grid.Column="2" Style="{StaticResource PillToggle}" Content="Tree view" Margin="0,0,10,0" Visibility="Collapsed"/>
        <Button x:Name="ExportButton" Grid.Column="3" Style="{StaticResource Secondary}" IsEnabled="False">
          <StackPanel Orientation="Horizontal">
            <TextBlock Style="{StaticResource Glyph}" Text="&#xE896;" FontSize="14" Margin="0,0,6,0"/>
            <TextBlock Text="Export" VerticalAlignment="Center"/>
          </StackPanel>
        </Button>
      </Grid>

      <!-- scope note (what the results actually represent) + divider -->
      <StackPanel Grid.Row="4" Margin="20,2,20,0">
        <StackPanel Orientation="Horizontal" Margin="0,0,0,5">
          <TextBlock Style="{StaticResource Glyph}" Text="&#xE946;" FontSize="12" Foreground="#9AA0A6" VerticalAlignment="Center" Margin="0,0,6,0"/>
          <TextBlock x:Name="ScopeNote" Foreground="#9AA0A6" FontSize="11.5" TextWrapping="Wrap" VerticalAlignment="Center"
                     Text="Each row is a place this user's access is granted (a route) - not every file they can open."/>
        </StackPanel>
        <Border Height="1" Background="{DynamicResource Line}"/>
      </StackPanel>

      <!-- RESULTS GRID: one row per route, sortable/filterable/groupable columns -->
      <Grid Grid.Row="5" Margin="20,0,20,0">
        <DataGrid x:Name="ResultsGrid" AutoGenerateColumns="False" IsReadOnly="True" Visibility="Collapsed"
                  HeadersVisibility="Column" GridLinesVisibility="None" BorderThickness="0"
                  Background="Transparent" RowBackground="{DynamicResource RowBg}" CanUserAddRows="False"
                  CanUserResizeRows="False" RowHeaderWidth="0" SelectionMode="Single"
                  CanUserSortColumns="False"
                  VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                  EnableRowVirtualization="True" FontSize="13" Foreground="{DynamicResource Ink}">
          <DataGrid.GroupStyle>
            <GroupStyle>
              <GroupStyle.ContainerStyle>
                <Style TargetType="{x:Type GroupItem}">
                  <Setter Property="Template">
                    <Setter.Value>
                      <ControlTemplate TargetType="{x:Type GroupItem}">
                        <Expander IsExpanded="True" Background="Transparent" BorderThickness="0" Margin="0,4,0,0">
                          <Expander.Header>
                            <StackPanel Orientation="Horizontal">
                              <Ellipse Width="8" Height="8" Margin="0,0,8,0" VerticalAlignment="Center">
                                <Ellipse.Style>
                                  <Style TargetType="Ellipse">
                                    <Setter Property="Fill" Value="#C4C9D0"/>
                                    <Style.Triggers>
                                      <DataTrigger Binding="{Binding Name}" Value="Overshared"><Setter Property="Fill" Value="{DynamicResource OversharedPillFg}"/></DataTrigger>
                                      <DataTrigger Binding="{Binding Name}" Value="Granted"><Setter Property="Fill" Value="{DynamicResource GrantedPillFg}"/></DataTrigger>
                                    </Style.Triggers>
                                  </Style>
                                </Ellipse.Style>
                              </Ellipse>
                              <TextBlock Text="{Binding Name}" FontWeight="SemiBold" Foreground="{DynamicResource Ink}"/>
                              <TextBlock Text="{Binding ItemCount, StringFormat=' ({0})'}" Foreground="{DynamicResource Subtle}"/>
                            </StackPanel>
                          </Expander.Header>
                          <ItemsPresenter/>
                        </Expander>
                      </ControlTemplate>
                    </Setter.Value>
                  </Setter>
                </Style>
              </GroupStyle.ContainerStyle>
            </GroupStyle>
          </DataGrid.GroupStyle>
          <DataGrid.ColumnHeaderStyle>
            <Style TargetType="DataGridColumnHeader">
              <Setter Property="Foreground" Value="{DynamicResource Subtle}"/>
              <Setter Property="FontSize" Value="12"/>
              <Setter Property="FontWeight" Value="SemiBold"/>
              <Setter Property="Cursor" Value="Hand"/>
              <Setter Property="Template">
                <Setter.Value>
                  <ControlTemplate TargetType="DataGridColumnHeader">
                    <Grid>
                      <Border BorderBrush="{DynamicResource Line}" BorderThickness="0,0,0,1" Background="Transparent">
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="4,8,2,8">
                          <ContentPresenter VerticalAlignment="Center"/>
                          <!-- sort direction: a small triangle, distinct from the menu chevron -->
                          <TextBlock x:Name="SortGlyph" Text="" FontSize="8" Foreground="{DynamicResource Subtle}"
                                     VerticalAlignment="Center" Margin="6,1,0,0"/>
                          <!-- menu trigger, sits right next to the label like SharePoint -->
                          <Button x:Name="HdrChevron" Background="Transparent" BorderThickness="0" Cursor="Hand"
                                  Padding="2,0,2,0" Margin="4,0,0,0" ToolTip="Sort, group and filter">
                            <TextBlock Style="{StaticResource Glyph}" Text="&#xE70D;" FontSize="10" Foreground="{DynamicResource Subtle}"/>
                          </Button>
                        </StackPanel>
                      </Border>
                      <!-- drag these edges to resize the column -->
                      <Thumb x:Name="PART_LeftHeaderGripper"  HorizontalAlignment="Left"  Style="{StaticResource ColHeaderGripper}"/>
                      <Thumb x:Name="PART_RightHeaderGripper" HorizontalAlignment="Right" Style="{StaticResource ColHeaderGripper}"/>
                    </Grid>
                    <ControlTemplate.Triggers>
                      <Trigger Property="SortDirection" Value="Ascending">
                        <Setter TargetName="SortGlyph" Property="Text" Value="&#x25B2;"/>
                      </Trigger>
                      <Trigger Property="SortDirection" Value="Descending">
                        <Setter TargetName="SortGlyph" Property="Text" Value="&#x25BC;"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </Setter.Value>
              </Setter>
            </Style>
          </DataGrid.ColumnHeaderStyle>
          <DataGrid.CellStyle>
            <Style TargetType="DataGridCell">
              <Setter Property="BorderThickness" Value="0"/>
              <Setter Property="Padding" Value="4,10,4,10"/>
              <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
              <Setter Property="Background" Value="Transparent"/>
              <Setter Property="Template">
                <Setter.Value>
                  <ControlTemplate TargetType="DataGridCell">
                    <Border Padding="{TemplateBinding Padding}" Background="{TemplateBinding Background}">
                      <ContentPresenter VerticalAlignment="Top"/>
                    </Border>
                  </ControlTemplate>
                </Setter.Value>
              </Setter>
              <Style.Triggers>
                <!-- keep text visible on selection (default turns it white) -->
                <Trigger Property="IsSelected" Value="True">
                  <Setter Property="Background" Value="{DynamicResource SelBg}"/>
                  <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
                </Trigger>
              </Style.Triggers>
            </Style>
          </DataGrid.CellStyle>
          <DataGrid.RowStyle>
            <Style TargetType="DataGridRow">
              <Setter Property="BorderBrush" Value="{DynamicResource Line}"/>
              <Setter Property="BorderThickness" Value="0,0,0,1"/>
              <Style.Triggers>
                <DataTrigger Binding="{Binding IsUnexpected}" Value="True">
                  <Setter Property="Background" Value="{DynamicResource OversharedRow}"/>
                </DataTrigger>
              </Style.Triggers>
            </Style>
          </DataGrid.RowStyle>
          <DataGrid.Columns>
            <DataGridTemplateColumn Header="Risk" Width="120" SortMemberPath="RiskText">
              <DataGridTemplateColumn.CellTemplate>
                <DataTemplate>
                  <Border CornerRadius="10" Padding="9,3,9,3" HorizontalAlignment="Left" VerticalAlignment="Top">
                    <Border.Style>
                      <Style TargetType="Border">
                        <Setter Property="Background" Value="{DynamicResource GrantedPillBg}"/>
                        <Style.Triggers>
                          <DataTrigger Binding="{Binding IsUnexpected}" Value="True"><Setter Property="Background" Value="{DynamicResource OversharedPillBg}"/></DataTrigger>
                        </Style.Triggers>
                      </Style>
                    </Border.Style>
                    <TextBlock Text="{Binding RiskText}" FontSize="11.5" FontWeight="SemiBold">
                      <TextBlock.Style>
                        <Style TargetType="TextBlock">
                          <Setter Property="Foreground" Value="{DynamicResource GrantedPillFg}"/>
                          <Style.Triggers>
                            <DataTrigger Binding="{Binding IsUnexpected}" Value="True"><Setter Property="Foreground" Value="{DynamicResource OversharedPillFg}"/></DataTrigger>
                          </Style.Triggers>
                        </Style>
                      </TextBlock.Style>
                    </TextBlock>
                  </Border>
                </DataTemplate>
              </DataGridTemplateColumn.CellTemplate>
            </DataGridTemplateColumn>
            <DataGridTextColumn x:Name="ColWho" Header="User" Binding="{Binding Who}" Width="150" SortMemberPath="Who" Visibility="Collapsed">
              <DataGridTextColumn.ElementStyle>
                <Style TargetType="TextBlock"><Setter Property="TextTrimming" Value="CharacterEllipsis"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
              </DataGridTextColumn.ElementStyle>
            </DataGridTextColumn>
            <DataGridTemplateColumn Header="Site" Width="220" SortMemberPath="SiteTitle">
              <DataGridTemplateColumn.CellTemplate>
                <DataTemplate>
                  <DockPanel LastChildFill="True" ToolTip="{Binding SiteUrl}">
                    <!-- row action: always visible, opens this row's permissions page -->
                    <Button x:Name="PermButton" DockPanel.Dock="Right" Style="{StaticResource OpenPermBtn}" Margin="6,0,2,0"/>
                    <TextBlock Text="{Binding SiteTitle}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                  </DockPanel>
                </DataTemplate>
              </DataGridTemplateColumn.CellTemplate>
            </DataGridTemplateColumn>
            <DataGridTemplateColumn x:Name="ColObject" Header="Object" Width="220" SortMemberPath="ObjectKind">
              <DataGridTemplateColumn.CellTemplate>
                <DataTemplate>
                  <StackPanel Orientation="Horizontal" ToolTip="{Binding ObjectUrl}">
                    <TextBlock Style="{StaticResource Glyph}" Text="{Binding ObjectGlyph}" FontSize="13"
                               VerticalAlignment="Center" Margin="0,0,7,0"/>
                    <TextBlock Text="{Binding ObjectLabel}" Foreground="{DynamicResource Subtle}"
                               TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                  </StackPanel>
                </DataTemplate>
              </DataGridTemplateColumn.CellTemplate>
            </DataGridTemplateColumn>
            <DataGridTextColumn x:Name="ColLocation" Header="Location" Binding="{Binding Location}" Width="190" SortMemberPath="Location">
              <DataGridTextColumn.ElementStyle>
                <Style TargetType="TextBlock">
                  <Setter Property="ToolTip" Value="{Binding ObjectUrl}"/>
                  <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
                  <Setter Property="Foreground" Value="{DynamicResource Subtle}"/>
                </Style>
              </DataGridTextColumn.ElementStyle>
            </DataGridTextColumn>
            <DataGridTextColumn Header="Grant path" Binding="{Binding GrantPath}" Width="*" MinWidth="200" SortMemberPath="GrantPath">
              <DataGridTextColumn.ElementStyle>
                <Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/></Style>
              </DataGridTextColumn.ElementStyle>
            </DataGridTextColumn>
            <DataGridTextColumn Header="Effective" Binding="{Binding Effective}" Width="120" SortMemberPath="Effective"/>
          </DataGrid.Columns>
        </DataGrid>

        <!-- TREE VIEW: Site > Subsite > Library/List > Folder > Item, with
             expand/collapse and dashed parent-child connector lines. -->
        <TreeView x:Name="ResultsTree" Visibility="Collapsed" BorderThickness="0" Background="Transparent"
                  ScrollViewer.HorizontalScrollBarVisibility="Auto" VirtualizingStackPanel.IsVirtualizing="False">
          <TreeView.ItemContainerStyle>
            <Style TargetType="TreeViewItem">
              <Setter Property="IsExpanded" Value="{Binding IsExpanded, Mode=TwoWay}"/>
              <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
              <Setter Property="Padding" Value="2"/>
            </Style>
          </TreeView.ItemContainerStyle>
          <TreeView.ItemTemplate>
            <HierarchicalDataTemplate ItemsSource="{Binding Children}">
              <StackPanel Orientation="Horizontal" Margin="0,2,0,2" ToolTip="{Binding Url}">
                <TextBlock Text="{Binding Glyph}" FontFamily="Segoe MDL2 Assets" FontSize="14" VerticalAlignment="Center" Margin="0,0,7,0">
                  <TextBlock.Style>
                    <Style TargetType="TextBlock">
                      <Setter Property="Foreground" Value="#8A9099"/>
                      <Style.Triggers>
                        <DataTrigger Binding="{Binding Kind}" Value="Site"><Setter Property="Foreground" Value="#036C70"/></DataTrigger>
                        <DataTrigger Binding="{Binding Kind}" Value="Subsite"><Setter Property="Foreground" Value="#036C70"/></DataTrigger>
                        <DataTrigger Binding="{Binding Kind}" Value="Library"><Setter Property="Foreground" Value="#0F6CBD"/></DataTrigger>
                        <DataTrigger Binding="{Binding Kind}" Value="List"><Setter Property="Foreground" Value="#0F6CBD"/></DataTrigger>
                      </Style.Triggers>
                    </Style>
                  </TextBlock.Style>
                </TextBlock>
                <TextBlock Text="{Binding Name}" FontWeight="SemiBold" Foreground="{DynamicResource Ink}" VerticalAlignment="Center"/>
                <TextBlock Text="{Binding CountLabel}" Foreground="#9AA0A6" FontSize="11" VerticalAlignment="Center" Margin="8,0,0,0"/>
                <Border CornerRadius="9" Padding="7,1,7,1" Margin="10,0,0,0" VerticalAlignment="Center" Visibility="{Binding RiskVisibility}">
                  <Border.Style>
                    <Style TargetType="Border">
                      <Setter Property="Background" Value="{DynamicResource GrantedPillBg}"/>
                      <Style.Triggers>
                        <DataTrigger Binding="{Binding IsUnexpected}" Value="True"><Setter Property="Background" Value="{DynamicResource OversharedPillBg}"/></DataTrigger>
                      </Style.Triggers>
                    </Style>
                  </Border.Style>
                  <TextBlock Text="{Binding RiskText}" FontSize="10.5" FontWeight="SemiBold">
                    <TextBlock.Style>
                      <Style TargetType="TextBlock">
                        <Setter Property="Foreground" Value="{DynamicResource GrantedPillFg}"/>
                        <Style.Triggers>
                          <DataTrigger Binding="{Binding IsUnexpected}" Value="True"><Setter Property="Foreground" Value="{DynamicResource OversharedPillFg}"/></DataTrigger>
                        </Style.Triggers>
                      </Style>
                    </TextBlock.Style>
                  </TextBlock>
                </Border>
                <TextBlock Text="{Binding GrantPath}" Foreground="{DynamicResource Subtle}" VerticalAlignment="Center" Margin="10,0,0,0"/>
                <TextBlock Text="{Binding Effective}" Foreground="#9AA0A6" VerticalAlignment="Center" Margin="10,0,0,0" FontStyle="Italic"/>
                <Button x:Name="PermButton" Style="{StaticResource OpenPermBtn}" Margin="10,0,0,0"/>
              </StackPanel>
            </HierarchicalDataTemplate>
          </TreeView.ItemTemplate>
        </TreeView>

        <TextBlock x:Name="EmptyState" HorizontalAlignment="Center" VerticalAlignment="Center"
                   Foreground="#9AA0A6" FontSize="14" TextAlignment="Center" MaxWidth="440" TextWrapping="Wrap"
                   Text="Connect, pick a user, and run a scan to see what they can reach - and how."/>
      </Grid>

      <!-- FOOTER -->
      <Border Grid.Row="6" Background="{DynamicResource TileBg}" CornerRadius="0,0,10,10" BorderBrush="{DynamicResource Line}" BorderThickness="0,1,0,0" Padding="20,10,14,10">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <ProgressBar x:Name="Progress" Grid.Column="0" Width="150" Height="6" Minimum="0" Maximum="100"
                       Visibility="Collapsed" VerticalAlignment="Center" Foreground="{StaticResource Accent}" Background="{DynamicResource FieldBorder}" BorderThickness="0"/>
          <TextBlock x:Name="StatusText" Grid.Column="1" VerticalAlignment="Center" Margin="12,0,0,0"
                     Foreground="{DynamicResource Subtle}" Text="Open settings to connect."/>
          <Button x:Name="StopButton" Grid.Column="2" Style="{StaticResource Secondary}" Content="Stop" Width="80" Visibility="Collapsed"/>
        </Grid>
      </Border>
    </Grid>
  </Border>

  <!-- SAVED SCANS VIEW -->
  <Border x:Name="SavedView" Visibility="Collapsed" Margin="14" Background="{DynamicResource Surface}" CornerRadius="10"
          BorderBrush="{DynamicResource Line}" BorderThickness="1">
    <Grid Margin="0">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <StackPanel Grid.Row="0" Margin="20,16,20,12">
        <TextBlock Text="Scan history" FontSize="18" FontWeight="SemiBold" Foreground="{DynamicResource Ink}"/>
        <TextBlock Text="Reload a past scan instantly - Scan always re-runs live" FontSize="12.5" Foreground="{DynamicResource Subtle}" Margin="0,1,0,0"/>
      </StackPanel>
      <Border Grid.Row="0" Height="1" Background="{DynamicResource Line}" VerticalAlignment="Bottom"/>

      <ScrollViewer Grid.Row="1" Margin="20,8,20,16" VerticalScrollBarVisibility="Auto">
        <ItemsControl x:Name="SavedList">
          <ItemsControl.ItemTemplate>
            <DataTemplate>
              <Border Background="{DynamicResource TileBg}" CornerRadius="8" Padding="14,10,10,10" Margin="0,0,0,8"
                      BorderBrush="{DynamicResource Line}" BorderThickness="1">
                <DockPanel>
                  <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="OpenScanBtn" Style="{StaticResource Secondary}" Content="Open" Width="72" Height="30" Margin="0,0,8,0"/>
                    <Button x:Name="DelScanBtn"  Style="{StaticResource IconButton}" Content="&#xE74D;" ToolTip="Delete this saved scan"/>
                  </StackPanel>
                  <StackPanel>
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="{Binding UserDisplay}" FontWeight="SemiBold" Foreground="{DynamicResource Ink}"/>
                      <TextBlock Text="  &#xB7;  " Foreground="{DynamicResource Subtle}"/>
                      <TextBlock Text="{Binding ScopeDisplay}" Foreground="{DynamicResource Subtle}"/>
                    </StackPanel>
                    <TextBlock Text="{Binding TargetUrl}" FontSize="11" Foreground="#9AA0A6" TextTrimming="CharacterEllipsis" Margin="0,3,0,0" ToolTip="{Binding Target}">
                      <TextBlock.Style>
                        <Style TargetType="TextBlock">
                          <Style.Triggers>
                            <DataTrigger Binding="{Binding TargetUrl}" Value=""><Setter Property="Visibility" Value="Collapsed"/></DataTrigger>
                          </Style.Triggers>
                        </Style>
                      </TextBlock.Style>
                    </TextBlock>
                    <StackPanel Orientation="Horizontal" Margin="0,3,0,0">
                      <TextBlock Text="{Binding When}" FontSize="12" Foreground="#9AA0A6"/>
                      <TextBlock Text="{Binding RouteCount, StringFormat='   &#xB7;   {0} routes'}" FontSize="12" Foreground="#9AA0A6"/>
                      <TextBlock Text="{Binding OversharedCount, StringFormat=', {0} overshared'}" FontSize="12" Foreground="{DynamicResource TileDanger}"/>
                    </StackPanel>
                  </StackPanel>
                </DockPanel>
              </Border>
            </DataTemplate>
          </ItemsControl.ItemTemplate>
        </ItemsControl>
      </ScrollViewer>

      <TextBlock x:Name="SavedEmpty" Grid.Row="1" HorizontalAlignment="Center" VerticalAlignment="Center"
                 Foreground="#9AA0A6" FontSize="14" Text="No scans yet - run a scan and it will appear here."/>
    </Grid>
  </Border>

  <!-- REPORTS VIEW -->
  <Border x:Name="ReportsView" Visibility="Collapsed" Margin="14" Background="{DynamicResource Surface}" CornerRadius="10"
          BorderBrush="{DynamicResource Line}" BorderThickness="1">
    <Grid Margin="0">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <StackPanel Grid.Row="0" Margin="20,16,20,12">
        <TextBlock Text="Reports" FontSize="18" FontWeight="SemiBold" Foreground="{DynamicResource Ink}"/>
        <TextBlock Text="Every report you export is kept here - open or delete it anytime" FontSize="12.5" Foreground="{DynamicResource Subtle}" Margin="0,1,0,0"/>
      </StackPanel>
      <Border Grid.Row="0" Height="1" Background="{DynamicResource Line}" VerticalAlignment="Bottom"/>

      <ScrollViewer Grid.Row="1" Margin="20,8,20,16" VerticalScrollBarVisibility="Auto">
        <ItemsControl x:Name="ReportsList">
          <ItemsControl.ItemTemplate>
            <DataTemplate>
              <Border Background="{DynamicResource TileBg}" CornerRadius="8" Padding="14,10,10,10" Margin="0,0,0,8"
                      BorderBrush="{DynamicResource Line}" BorderThickness="1">
                <DockPanel>
                  <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="OpenReportBtn" Style="{StaticResource Secondary}" Content="Open" Width="72" Height="30" Margin="0,0,8,0"/>
                    <Button x:Name="DelReportBtn"  Style="{StaticResource IconButton}" Content="&#xE74D;" ToolTip="Delete this report"/>
                  </StackPanel>
                  <StackPanel>
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="{Binding UserDisplay}" FontWeight="SemiBold" Foreground="{DynamicResource Ink}"/>
                      <TextBlock Text="  &#xB7;  " Foreground="{DynamicResource Subtle}"/>
                      <TextBlock Text="{Binding ScopeDisplay}" Foreground="{DynamicResource Subtle}"/>
                      <Border Background="{DynamicResource IconBlue}" CornerRadius="4" Padding="6,1,6,1" Margin="8,0,0,0" VerticalAlignment="Center">
                        <TextBlock Text="{Binding Format}" FontSize="10.5" FontWeight="SemiBold" Foreground="{DynamicResource Accent}"/>
                      </Border>
                    </StackPanel>
                    <TextBlock Text="{Binding TargetUrl}" FontSize="11" Foreground="#9AA0A6" TextTrimming="CharacterEllipsis" Margin="0,3,0,0" ToolTip="{Binding Target}">
                      <TextBlock.Style>
                        <Style TargetType="TextBlock">
                          <Style.Triggers>
                            <DataTrigger Binding="{Binding TargetUrl}" Value=""><Setter Property="Visibility" Value="Collapsed"/></DataTrigger>
                          </Style.Triggers>
                        </Style>
                      </TextBlock.Style>
                    </TextBlock>
                    <StackPanel Orientation="Horizontal" Margin="0,3,0,0">
                      <TextBlock Text="{Binding When}" FontSize="12" Foreground="#9AA0A6"/>
                      <TextBlock Text="{Binding RouteCount, StringFormat='   &#xB7;   {0} routes'}" FontSize="12" Foreground="#9AA0A6"/>
                    </StackPanel>
                  </StackPanel>
                </DockPanel>
              </Border>
            </DataTemplate>
          </ItemsControl.ItemTemplate>
        </ItemsControl>
      </ScrollViewer>

      <TextBlock x:Name="ReportsEmpty" Grid.Row="1" HorizontalAlignment="Center" VerticalAlignment="Center"
                 Foreground="#9AA0A6" FontSize="14" Text="No reports yet - run a scan and click Export to create one."/>
    </Grid>
  </Border>

    </Grid>  <!-- /content -->
  </Grid>    <!-- /shell -->

  <!-- settings popup (connection) -->
</Window>
'@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $get = { param($n) $window.FindName($n) }
    $userCombo   = & $get 'UserCombo';    $userPlace = & $get 'UserPlaceholder'
    $compareLink = & $get 'CompareLink'; $userRowB = & $get 'UserRowB'; $userComboB = & $get 'UserComboB'; $userPlaceB = & $get 'UserPlaceholderB'; $colWho = & $get 'ColWho'
    $scopeCombo  = & $get 'ScopeCombo';   $scanBtn   = & $get 'ScanButton'
    $siteRow     = & $get 'SiteRow';      $siteCombo = & $get 'SiteCombo';  $sitePlace = & $get 'SitePlaceholder'
    $tenantChip  = & $get 'TenantChip';   $chipText  = & $get 'TenantChipText'; $chipIcon = & $get 'TenantChipIcon'
    $settingsBtn = & $get 'SettingsButton'
    $tileRoutes  = & $get 'TileRoutes';   $tileUnexp = & $get 'TileUnexpected'; $tileUnexpCard = & $get 'TileUnexpectedCard'
    $tileRoutesLabel = & $get 'TileRoutesLabel'; $tileUnexpLabel = & $get 'TileUnexpLabel'; $tileSitesLabel = & $get 'TileSitesLabel'; $tileAccessLabel = & $get 'TileAccessLabel'
    $tileSites   = & $get 'TileSites';    $tileAccess = & $get 'TileAccess'
    $filterBox   = & $get 'FilterBox';    $filterPlace = & $get 'FilterPlaceholder'
    $exportBtn = & $get 'ExportButton'
    $viewToggle = & $get 'ViewToggle'; $resultsTree = & $get 'ResultsTree'; $scopeNote = & $get 'ScopeNote'
    $colObject = & $get 'ColObject'; $colLocation = & $get 'ColLocation'; $oversharedToggle = & $get 'OversharedToggle'
    $scanView = & $get 'ScanView'; $savedView = & $get 'SavedView'; $savedList = & $get 'SavedList'; $savedEmpty = & $get 'SavedEmpty'
    $navScan = & $get 'NavScan'; $navSaved = & $get 'NavSaved'; $themeToggle = & $get 'ThemeToggle'
    $versionButton = & $get 'VersionButton'; $versionText = & $get 'VersionText'; $updateBadge = & $get 'UpdateBadge'
    $railBorder = & $get 'RailBorder'; $railDock = & $get 'RailDock'; $railToggle = & $get 'RailToggle'
    $window.Resources['NavTextVis'] = [System.Windows.Visibility]::Visible   # rail labels shown by default
    $script:appVersion = try { "$((Import-PowerShellDataFile $ModulePath).ModuleVersion)" } catch { '0.0.0' }
    $script:repo = 'gvijaikumar9/UserAccessExplorer'
    $script:guideUrl = 'https://fivenumber.com/user-access-explorer/'   # author's guide / write-up
    $versionText.Text = "v$($script:appVersion)"
    $navReports = & $get 'NavReports'; $reportsView = & $get 'ReportsView'; $reportsList = & $get 'ReportsList'; $reportsEmpty = & $get 'ReportsEmpty'
    $list        = & $get 'ResultsGrid';  $emptyState = & $get 'EmptyState'
    $progress    = & $get 'Progress';     $status = & $get 'StatusText'; $stopBtn = & $get 'StopButton'

    # brushes reused across view models
    $brInk   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x24,0x24,0x24))
    $brRed   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xB1,0x0E,0x1C))
    $brGreen = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x10,0x7C,0x41))
    $brSubtle= New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x70,0x78,0x82))
    $riskBgU = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xFC,0xE7,0xEA))
    $riskFgU = $brRed
    $riskBgE = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xEA,0xF1,0xE7))
    $riskFgE = $brGreen
    foreach ($b in $brInk,$brRed,$brGreen,$brSubtle,$riskBgU,$riskBgE) { $b.Freeze() }

    $cleanVia = {
        param($grantedVia)
        if ($grantedVia -match "^Everyone claim \((.+)\)$") { return $matches[1] }
        if ($grantedVia -match "^SharePoint group '(.+)'$") { return $matches[1] }
        if ($grantedVia -match "^Entra group '(.+?)'")      { return $matches[1] }
        return $grantedVia
    }
    $accessRank = { param($a) switch ($a) { 'Full Control' {3} 'Edit' {2} 'Read' {1} default {0} } }

    # --- turn flat routes into site-grouped view models ----------------------
    $script:allGroups = @()
    # One display row per route. Grant path is its own column (via -> permission),
    # so the "how" is always visible and every route is independently
    # sortable / filterable / groupable in the grid.
    $buildRows = {
        param($rows)
        # Compare mode: work out which site/object each user can reach, so every
        # row can be bucketed Shared / Only A / Only B. Key by object URL (deep) or
        # site URL. Short display names keep the "Who" column and group labels tidy.
        $keyFor = { param($rr) if (($rr.PSObject.Properties.Name -contains 'ObjectUrl') -and $rr.ObjectUrl) { "$($rr.ObjectUrl)" } else { "$($rr.SiteUrl)" } }
        $setA = @{}; $setB = @{}
        $shortA = ("$($script:cmpUserA)" -split ' - ')[0]; $shortB = ("$($script:cmpUserB)" -split ' - ')[0]
        if ($script:isCompare) {
            foreach ($r in $rows) { $k = & $keyFor $r; if ("$($r.CmpUser)" -eq 'B') { $setB[$k] = $true } else { $setA[$k] = $true } }
        }
        $out = foreach ($r in $rows) {
            $via     = & $cleanVia $r.GrantedVia
            $isUnexp = $r.RouteType -eq 'Overshared'
            $isRoot  = "$($r.SiteUrl)" -notmatch '/(sites|teams)/'
            $site    = if ($isRoot) { "$($r.SiteTitle) (root)" } else { "$($r.SiteTitle)" }

            # Deep rows carry a precise object kind (Site/Subsite/Library/List/
            # Folder/File/Item); site-level rows do not, so their Object is blank.
            $objKind  = if ($r.PSObject.Properties.Name -contains 'ObjectKind') { "$($r.ObjectKind)" } else { '' }
            $objTitle = if ($r.PSObject.Properties.Name -contains 'ObjectTitle') { "$($r.ObjectTitle)" } else { '' }
            $objUrl   = if (($r.PSObject.Properties.Name -contains 'ObjectUrl') -and $r.ObjectUrl) { "$($r.ObjectUrl)" } else { "$($r.SiteUrl)" }
            $objLabel =
                if (-not $objKind)           { '' }
                elseif ($objKind -eq 'Site') { 'Site' }
                else                         { "$objKind : $objTitle" }
            $objGlyph = switch ($objKind) {
                'Site'    { [char]0xE774 }  'Subsite' { [char]0xE774 }   # globe
                'Library' { [char]0xE8F1 }                                # library
                'List'    { [char]0xE8FD }                                # bulleted list
                'Folder'  { [char]0xE8B7 }                                # folder
                'File'    { [char]0xE7C3 }  'Item'    { [char]0xE7C3 }   # page
                default   { '' }
            }

            # breadcrumb of where the object lives, so the hierarchy is legible
            # without a tree: Library > Folder > subfolder (the object's container)
            $rel  = "$objUrl" -replace '^https?://[^/]+', '' -replace '^/(sites|teams)/[^/]+', ''
            $segs = @($rel.Trim('/') -split '/' | Where-Object { $_ })
            if ($segs.Count -gt 0 -and $segs[0] -eq 'Lists') { $segs = @($segs | Select-Object -Skip 1) }
            $sep = " $([char]0x203A) "
            $location = if ($segs.Count -gt 1) { ($segs[0..($segs.Count - 2)] -join $sep) } else { '' }

            [pscustomobject]@{
                RiskText     = $r.RouteType
                RiskBg       = if ($isUnexp) { $riskBgU } else { $riskBgE }
                RiskFg       = if ($isUnexp) { $riskFgU } else { $riskFgE }
                IsUnexpected = $isUnexp
                SiteTitle    = $site
                SiteUrl      = $r.SiteUrl
                ObjectKind   = $objKind
                ObjectLabel  = $objLabel
                ObjectGlyph  = $objGlyph
                ObjectUrl    = $objUrl
                PermUrl      = if (($r.PSObject.Properties.Name -contains 'PermUrl') -and $r.PermUrl) { "$($r.PermUrl)" } else { "$objUrl/_layouts/15/user.aspx" }
                Location     = $location
                GrantPath    = if ($r.Permission) { "$via -> $($r.Permission)" } else { "$via" }
                Effective    = $r.EffectiveAccess
                Who          = if ($script:isCompare) { if ("$($r.CmpUser)" -eq 'B') { $shortB } else { $shortA } } else { '' }
                CompareStatus = if ($script:isCompare) {
                                    $k = & $keyFor $r
                                    if ($setA.ContainsKey($k) -and $setB.ContainsKey($k)) { 'Shared by both' }
                                    elseif ("$($r.CmpUser)" -eq 'B') { "Only $shortB" }
                                    else { "Only $shortA" }
                                } else { '' }
                FilterKey    = "$($r.SiteTitle) $($r.SiteUrl) $objKind $objLabel $location $via $($r.Permission) $($r.RouteType)".ToLower()
            }
        }
        # unexpected first, then by site
        @($out | Sort-Object @{ e = { if ($_.IsUnexpected) { 0 } else { 1 } } }, SiteTitle)
    }

    $glyphForKind = {
        param($kind)
        switch ($kind) {
            'Site'    { [char]0xE774 }  'Subsite' { [char]0xE774 }
            'Library' { [char]0xE8F1 }  'List'    { [char]0xE8FD }
            'Folder'  { [char]0xE8B7 }
            'File'    { [char]0xE7C3 }  'Item'    { [char]0xE7C3 }
            default   { [char]0xE7C3 }
        }
    }

    # Build the Site > Library/List > Folder > Item hierarchy from the flat deep
    # rows. Intermediate containers that had no access row of their own are
    # synthesised from the path so the tree has no gaps.
    $buildTree = {
        param($rows)
        $rows = [object[]]$rows   # cast, not @() - @() on a List throws in PS 7.6.3
        if ($rows.Count -eq 0) { return $null }

        $mkNode = {
            param($name, $kind, $url, $fromScan = $false, $permUrl = '')
            $n = [UaeNode]::new()
            $n.Name = "$name"; $n.Kind = $kind; $n.Glyph = (& $glyphForKind $kind); $n.Url = "$url"
            $n.PermUrl = "$permUrl"
            $n.RiskBg = $riskBgE; $n.RiskFg = $riskFgE; $n.FromScan = $fromScan
            $n
        }

        $root = & $mkNode $rows[0].SiteTitle 'Site' $rows[0].SiteUrl $false "$($rows[0].SiteUrl)/_layouts/15/user.aspx"
        $index = @{ '' = $root }

        # shallow paths first, so a container exists before its children
        foreach ($r in ($rows | Sort-Object @{ e = { ("$($_.ObjectUrl)" -split '/').Count } })) {
            $rel  = "$($r.ObjectUrl)" -replace '^https?://[^/]+', '' -replace '^/(sites|teams)/[^/]+', ''
            $segs = @($rel.Trim('/') -split '/' | Where-Object { $_ })
            if ($segs.Count -gt 0 -and $segs[0] -eq 'Lists') { $segs = @($segs | Select-Object -Skip 1) }

            $cc = if ($r.PSObject.Properties.Name -contains 'ContainerCount') { [int]$r.ContainerCount } else { -1 }
            $target = $root
            if ($segs.Count -gt 0) {
                $parent = $root; $path = ''
                for ($i = 0; $i -lt $segs.Count; $i++) {
                    $path = "$path/$($segs[$i])"
                    $isLeaf = ($i -eq $segs.Count - 1)
                    if (-not $index.ContainsKey($path)) {
                        $leafPerm = if (($r.PSObject.Properties.Name -contains 'PermUrl') -and $r.PermUrl) { "$($r.PermUrl)" } else { '' }
                        $node = if ($isLeaf) { & $mkNode $r.ObjectTitle $r.ObjectKind $r.ObjectUrl $true $leafPerm }
                                else          { & $mkNode $segs[$i] $(if ($i -eq 0) { 'Library' } else { 'Folder' }) '' $false }
                        [void]$parent.Children.Add($node)
                        $index[$path] = $node
                    }
                    # the top-level container (list/library) carries the item total
                    if ($i -eq 0 -and $cc -ge 0 -and $index[$path].TotalCount -lt 0) { $index[$path].TotalCount = $cc }
                    $parent = $index[$path]
                }
                $target = $parent
            }

            # stamp the access info onto the object node (prefer an overshared route)
            $isUnexp = $r.RouteType -eq 'Overshared'
            if ($isUnexp -or $target.RiskText -eq '') {
                $via = & $cleanVia $r.GrantedVia
                $target.GrantPath = if ($r.Permission) { "$via -> $($r.Permission)" } else { "$via" }
                $target.Effective = $r.EffectiveAccess
            }
            if ($isUnexp) { $target.IsUnexpected = $true }
            if ($target.IsUnexpected) {
                $target.RiskText = 'Overshared'; $target.RiskBg = $riskBgU; $target.RiskFg = $riskFgU; $target.RiskVisibility = 'Visible'
            } elseif ($target -ne $root) {
                $target.RiskText = 'Granted'; $target.RiskBg = $riskBgE; $target.RiskFg = $riskFgE; $target.RiskVisibility = 'Visible'
            }
        }

        # On each list/library (the nodes that carry a total), annotate how many
        # of its items actually had their own permissions - so "3 of 400" makes
        # clear the other 397 inherit and were not a distinct access route.
        $countReal = {
            param($node)
            $c = 0
            foreach ($child in $node.Children) {
                if ($child.FromScan) { $c++ }
                $c += (& $countReal $child)
            }
            $c
        }
        $annotate = {
            param($node)
            if ($node.TotalCount -ge 0) {
                $node.CountLabel = "$(& $countReal $node) of $($node.TotalCount) with unique permissions"
            }
            foreach ($child in $node.Children) { & $annotate $child }
        }
        & $annotate $root
        return $root
    }

    # sort / group / per-column filter state, driven by the header menus.
    # colFilters: field -> the single allowed value for that column (absent = all)
    $script:sortField = $null; $script:sortDir = 'Ascending'; $script:groupField = $null
    $script:colFilters = @{}
    $script:oversharedOnly = $false

    $applyView = {
        $term = "$($filterBox.Text)".Trim().ToLower()
        $view = foreach ($row in $script:allRows) {
            if ($term -and $row.FilterKey -notlike "*$term*") { continue }
            if ($script:oversharedOnly -and -not $row.IsUnexpected) { continue }
            $keep = $true
            foreach ($fld in $script:colFilters.Keys) {
                if ("$($row.$fld)" -ne "$($script:colFilters[$fld])") { $keep = $false; break }
            }
            if (-not $keep) { continue }
            $row
        }
        $view = [object[]]@($view)

        # Pre-sort in PowerShell. ListCollectionView.SortDescriptions sorts via
        # CLR reflection, which does NOT see a PSCustomObject's dynamic properties,
        # so it silently no-ops. Sort-Object handles PSObjects correctly.
        if ($script:sortField) {
            $desc = ($script:sortDir -eq 'Descending')
            $view = [object[]]@($view | Sort-Object -Property $script:sortField -Descending:$desc)
        }

        # A collection view so the grid can group by the chosen column. (Grouping
        # DOES understand PSObjects because PropertyGroupDescription uses binding.)
        $cv = New-Object System.Windows.Data.ListCollectionView (,$view)
        if ($script:groupField) {
            $cv.GroupDescriptions.Add((New-Object System.Windows.Data.PropertyGroupDescription $script:groupField))
        }
        $list.ItemsSource = $cv

        # reflect the sort arrow on the matching column header
        foreach ($c in $list.Columns) {
            $c.SortDirection = if ($script:sortField -and "$($c.SortMemberPath)" -eq $script:sortField) {
                if ($script:sortDir -eq 'Descending') { [System.ComponentModel.ListSortDirection]::Descending }
                else { [System.ComponentModel.ListSortDirection]::Ascending }
            } else { $null }
        }

        # Only show the grid once it has data. An empty DataGrid with a star column
        # collapses its fixed columns into a crammed strip of headers, so keep it
        # hidden (the empty-state text covers the "nothing yet" case) until rows exist.
        if (-not [bool]$viewToggle.IsChecked) {
            $list.Visibility = if ($script:allRows.Count -gt 0) { 'Visible' } else { 'Collapsed' }
        }

        $empty = ($view.Count -eq 0 -and $script:allRows.Count -gt 0)
        $emptyState.Visibility = if ($empty) { 'Visible' } else { 'Collapsed' }
        if ($empty) { $emptyState.Text = 'No rows match the current filter.' }
    }

    # Grid <-> Tree. The grid is the analyst view (filter/sort/group); the tree
    # is the structure view (Site > Library > Folder > Item, expand/collapse).
    $showView = {
        if ([bool]$viewToggle.IsChecked) {
            $root = & $buildTree $script:rows
            $col = New-Object System.Collections.ObjectModel.ObservableCollection[object]
            if ($root) { [void]$col.Add($root) }
            $resultsTree.ItemsSource = $col
            $resultsTree.Visibility = 'Visible'; $list.Visibility = 'Collapsed'
            $kids = if ($root) { $root.Children.Count } else { 0 }
            $status.Text = "Tree view: $kids top-level branch(es) under the site."
        } else {
            $resultsTree.Visibility = 'Collapsed'
            $list.Visibility = if ($script:allRows.Count -gt 0) { 'Visible' } else { 'Collapsed' }
        }
    }
    $viewToggle.Add_Click({ & $showView })
    $oversharedToggle.Add_Click({ $script:oversharedOnly = [bool]$oversharedToggle.IsChecked; & $applyView })

    # tree nodes carry the same open-permissions button; open the node's perms page
    $resultsTree.AddHandler(
        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [System.Windows.RoutedEventHandler]{
            $node = $args[1].OriginalSource
            while ($node) {
                if ($node -is [System.Windows.Controls.Button] -and $node.Name -eq 'PermButton') {
                    $ctx = $node.DataContext
                    if ($ctx -and $ctx.PermUrl) {
                        try { Start-Process $ctx.PermUrl } catch { $status.Text = "Could not open the permissions page: $($_.Exception.Message)" }
                    }
                    break
                }
                $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
            }
        }
    )

    # One shared, script-scope handler for every header menu item. The item's
    # Tag carries { Field; Action }. NOT a closure: closures get their own scope
    # module, so $script:* and $applyView would not resolve to this runspace.
    $onMenuClick = {
        $t = $this.Tag
        switch ($t.Action) {
            'SortAsc'     { $script:sortField = $t.Field; $script:sortDir = 'Ascending' }
            'SortDesc'    { $script:sortField = $t.Field; $script:sortDir = 'Descending' }
            'Group'       { $script:groupField = $t.Field }
            'Ungroup'     { $script:groupField = $null }
            'Filter'      { $script:colFilters[$t.Field] = $t.Value }
            'ClearFilter' { [void]$script:colFilters.Remove($t.Field) }
        }
        & $applyView
    }

    # SharePoint-style header interaction:
    #   click the LABEL   -> toggle sort ascending <-> descending
    #   click the CHEVRON -> full menu (sort / group / filter)
    $list.AddHandler(
        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [System.Windows.RoutedEventHandler]{
            $e = $args[1]
            $isChevron = $false; $chevron = $null; $node = $e.OriginalSource
            while ($node) {
                # a row's open-permissions button: jump to that object's perms page
                if ($node -is [System.Windows.Controls.Button] -and $node.Name -eq 'PermButton') {
                    $ctx = $node.DataContext
                    if ($ctx -and $ctx.PermUrl) {
                        try { Start-Process $ctx.PermUrl } catch { $status.Text = "Could not open the permissions page: $($_.Exception.Message)" }
                    }
                    return
                }
                if ($node -is [System.Windows.Controls.Button] -and $node.Name -eq 'HdrChevron') { $isChevron = $true; $chevron = $node }
                if ($node -is [System.Windows.Controls.Primitives.DataGridColumnHeader]) { break }
                $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
            }
            if (-not ($node -is [System.Windows.Controls.Primitives.DataGridColumnHeader])) { return }
            $col = $node.Column
            $field = "$($col.SortMemberPath)"
            if (-not $field) { return }

            if (-not $isChevron) {
                # clicked the header label: toggle sort, same as a SharePoint column
                if ($script:sortField -eq $field) {
                    $script:sortDir = if ($script:sortDir -eq 'Ascending') { 'Descending' } else { 'Ascending' }
                } else {
                    $script:sortField = $field; $script:sortDir = 'Ascending'
                }
                & $applyView
                return
            }

            # clicked the chevron: open the menu
            $menu = New-Object System.Windows.Controls.ContextMenu
            $mk = {
                param($text, $action)
                $mi = New-Object System.Windows.Controls.MenuItem
                $mi.Header = $text
                $mi.Tag = [pscustomobject]@{ Field = $field; Action = $action }
                $mi.Add_Click($onMenuClick)
                [void]$menu.Items.Add($mi)
            }
            & $mk 'Sort A to Z' 'SortAsc'
            & $mk 'Sort Z to A' 'SortDesc'
            [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
            if ($script:groupField -eq $field) { & $mk 'Remove grouping' 'Ungroup' }
            else { & $mk "Group by $($col.Header)" 'Group' }
            [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))

            # Filter by value: one checkable item per distinct value in this column.
            $vals = @($script:allRows | ForEach-Object { "$($_.$field)" } | Sort-Object -Unique)
            $active = "$($script:colFilters[$field])"
            foreach ($v in $vals) {
                $mi = New-Object System.Windows.Controls.MenuItem
                $mi.Header = $v; $mi.IsCheckable = $true
                $mi.IsChecked = ($active -eq $v)
                $mi.Tag = [pscustomobject]@{ Field = $field; Action = 'Filter'; Value = $v }
                $mi.Add_Click($onMenuClick)
                [void]$menu.Items.Add($mi)
            }
            if ($script:colFilters.ContainsKey($field)) { & $mk 'Clear filter' 'ClearFilter' }

            $menu.PlacementTarget = $chevron
            $menu.Placement = 'Bottom'
            $menu.IsOpen = $true
        }
    )

    $refreshTiles = {
        param($rows)
        # [object[]] cast, not @(): in PS 7.6.3 @() around a List[object] throws
        # "Argument types do not match". The cast handles both a List and @().
        $rows = [object[]]$rows
        $u = @($rows | Where-Object { $_.RouteType -eq 'Overshared' }).Count
        if ($script:isCompare) {
            # bucket by site/object (matching the grid grouping): Shared / Only A / Only B
            $keyFor = { param($rr) if (($rr.PSObject.Properties.Name -contains 'ObjectUrl') -and $rr.ObjectUrl) { "$($rr.ObjectUrl)" } else { "$($rr.SiteUrl)" } }
            $setA = @{}; $setB = @{}
            foreach ($r in $rows) { $k = & $keyFor $r; if ("$($r.CmpUser)" -eq 'B') { $setB[$k] = $true } else { $setA[$k] = $true } }
            $shared = 0; $onlyA = 0; $onlyB = 0
            foreach ($k in (@($setA.Keys) + @($setB.Keys) | Sort-Object -Unique)) {
                if ($setA.ContainsKey($k) -and $setB.ContainsKey($k)) { $shared++ } elseif ($setA.ContainsKey($k)) { $onlyA++ } else { $onlyB++ }
            }
            $shortA = ("$($script:cmpUserA)" -split ' - ')[0]; $shortB = ("$($script:cmpUserB)" -split ' - ')[0]
            $tileRoutesLabel.Text = 'Shared';        $tileRoutes.Text = "$shared"
            $tileSitesLabel.Text  = "Only $shortA";  $tileSites.Text  = "$onlyA"
            $tileAccessLabel.Text = "Only $shortB";  $tileAccess.Text = "$onlyB"; $tileAccess.Foreground = $window.Resources['Ink']
        } else {
            $tileRoutesLabel.Text = 'Routes found';  $tileRoutes.Text = "$($rows.Count)"
            $tileSitesLabel.Text  = 'Sites reached'; $tileSites.Text  = "$(@($rows | Select-Object -ExpandProperty SiteUrl -Unique).Count)"
            $highest = ($rows | Sort-Object @{ e = { & $accessRank $_.EffectiveAccess } } -Descending | Select-Object -First 1).EffectiveAccess
            $tileAccessLabel.Text = 'Highest access'; $tileAccess.Text = if ($highest) { $highest } else { '-' }
            $tileAccess.Foreground = if ($highest -eq 'Full Control') { $window.Resources['TileDanger'] } elseif ($highest -eq 'Edit') { $brSubtle } else { $window.Resources['Ink'] }
        }
        # Overshared tile is the same in both modes - and should shout when > 0
        $tileUnexpLabel.Text = 'Overshared'; $tileUnexp.Text = "$u"
        if ($u -gt 0) { $tileUnexpCard.Background = $window.Resources['TileOversharedBg']; $tileUnexp.Foreground = $window.Resources['TileDanger'] }
        else          { $tileUnexpCard.Background = $window.Resources['TileBg']; $tileUnexp.Foreground = $window.Resources['Ink'] }
    }

    # connection state (set on Connect; declared here so $loadSites can read it)
    $script:clientId = ''; $script:adminUrl = ''; $script:darkMode = $false

    # Remember Client ID + admin URL between sessions. Neither is a secret (the
    # client ID is a public app identifier, the URL is just a URL), so plain
    # JSON under the roaming profile is fine.
    $script:settingsPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'UserAccessExplorer\settings.json'
    $loadSettings = {
        try { if (Test-Path $script:settingsPath) { return Get-Content $script:settingsPath -Raw | ConvertFrom-Json } }
        catch { Write-Verbose "settings load skipped: $($_.Exception.Message)" }
        return $null
    }
    # Keep a short most-recent-first history of each, so admins juggling several
    # tenants / app registrations pick from a dropdown instead of retyping.
    $saveSettings = {
        param($ClientId, $AdminUrl)
        try {
            $existing = & $loadSettings
            $priorC = @(); $priorA = @()
            if ($existing) {
                $priorC = @(@($existing.ClientIds) + @($existing.ClientId))   # new arrays + old single value
                $priorA = @(@($existing.AdminUrls) + @($existing.AdminUrl))
            }
            $clients = @(@($ClientId) + @($priorC | Where-Object { $_ -and $_ -ne $ClientId }) | Where-Object { $_ } | Select-Object -First 10)
            $admins  = @(@($AdminUrl)  + @($priorA | Where-Object { $_ -and $_ -ne $AdminUrl })  | Where-Object { $_ } | Select-Object -First 10)
            $dir = Split-Path $script:settingsPath -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [pscustomobject]@{ ClientIds = $clients; AdminUrls = $admins; Theme = [bool]$script:darkMode } |
                ConvertTo-Json | Set-Content -Path $script:settingsPath -Encoding UTF8
        } catch { Write-Verbose "settings save skipped: $($_.Exception.Message)" }
    }

    # --- saved / recent scans ------------------------------------------------
    # Each completed scan is written to JSON under the roaming profile, keyed by
    # (user, mode, target) so re-scanning the same thing overwrites in place. The
    # Recent menu (overflow button) reloads any of them INSTANTLY - no SharePoint
    # round-trip - clearly stamped with when it was taken. Scan itself always runs
    # live, so a cached view is never mistaken for current permissions.
    $script:scansDir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'UserAccessExplorer\scans'
    $scanFileFor = {
        param($key)
        if (-not (Test-Path $script:scansDir)) { New-Item -ItemType Directory -Path $script:scansDir -Force | Out-Null }
        $md5  = [System.Security.Cryptography.MD5]::Create()
        $hash = ([System.BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes("$key")))) -replace '-'
        Join-Path $script:scansDir "$hash.json"
    }
    $pruneScans = {
        try {
            $files = @(Get-ChildItem $script:scansDir -Filter *.json -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            if ($files.Count -gt 25) { $files | Select-Object -Skip 25 | Remove-Item -Force -ErrorAction SilentlyContinue }
        } catch { Write-Verbose "prune scans skipped: $($_.Exception.Message)" }
    }
    $saveScan = {
        param($User, $UserDisplay, $Mode, $ScopeLabel, $Target, $Rows)
        try {
            # [object[]] cast, NOT @(): @() around a generic List[object] throws
            # "Argument types do not match" in PS 7.6.3 - this silently killed every
            # scan-save (Saved scans stayed empty while Reports worked).
            $arr = [object[]]$Rows
            [pscustomobject]@{
                User = "$User"; UserDisplay = "$UserDisplay"; Mode = "$Mode"; ScopeLabel = "$ScopeLabel"; Target = "$Target"
                Timestamp = (Get-Date).ToString('o')
                RouteCount = $arr.Count
                OversharedCount = @($arr | Where-Object { $_.RouteType -eq 'Overshared' }).Count
                Rows = $arr
            } | ConvertTo-Json -Depth 6 | Set-Content -Path (& $scanFileFor "$User|$Mode|$Target") -Encoding UTF8
            & $pruneScans
        } catch { Write-Verbose "save scan skipped: $($_.Exception.Message)" }
    }
    # Human "which site" label for a scan/report: tenant scans stay "Whole tenant";
    # site scans show the site name (from /sites/<x> or /teams/<x>) + a (deep) tag.
    $scopeDisplayFor = {
        param($ScopeLabel, $Target)
        if ("$ScopeLabel" -eq 'Whole tenant') { return 'Whole tenant' }
        $site = if ("$Target" -match '/(sites|teams)/([^/?#]+)') { $matches[2] } else { "$Target" -replace '^https?://', '' -replace '/.*$', '' }
        if (-not $site) { return "$ScopeLabel" }   # older records saved before Target was stored
        if ("$ScopeLabel" -like '*deep*') { "$site (deep)" } else { "$site" }
    }
    $listScans = {
        if (-not (Test-Path $script:scansDir)) { return @() }
        @(Get-ChildItem $script:scansDir -Filter *.json -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | ForEach-Object {
                try {
                    $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
                    $w = try { ([datetime]$j.Timestamp).ToString('MMM d, yyyy  HH:mm') } catch { "$($j.Timestamp)" }
                    $j | Add-Member -NotePropertyName When         -NotePropertyValue $w                                    -Force
                    $j | Add-Member -NotePropertyName ScopeDisplay -NotePropertyValue (& $scopeDisplayFor $j.ScopeLabel $j.Target) -Force
                    $j | Add-Member -NotePropertyName TargetUrl    -NotePropertyValue $(if ("$($j.ScopeLabel)" -eq 'Whole tenant') { 'All sites in the tenant' } elseif ("$($j.Target)") { "$($j.Target)" } else { '' }) -Force
                    $j | Add-Member -NotePropertyName _Path        -NotePropertyValue $_.FullName                           -Force
                    $j
                } catch { Write-Verbose "skipped unreadable scan file: $($_.Exception.Message)" }
            })
    }
    $loadScan = {
        param($Scan)
        $script:rows = New-Object System.Collections.Generic.List[object]
        foreach ($r in @($Scan.Rows)) { $script:rows.Add($r) }
        $script:isCompare = $false; $colWho.Visibility = 'Collapsed'   # saved scans reload as single-user
        $script:lastMode = "$($Scan.Mode)"
        if ($script:lastMode -eq 'Deep') {
            $viewToggle.Visibility = 'Visible'; $colObject.Visibility = 'Visible'; $colLocation.Visibility = 'Visible'
        } else {
            $viewToggle.Visibility = 'Collapsed'; $colObject.Visibility = 'Collapsed'; $colLocation.Visibility = 'Collapsed'
        }
        $script:allRows = & $buildRows $script:rows
        & $refreshTiles $script:rows
        $viewToggle.IsChecked = ($script:lastMode -eq 'Deep' -and $script:rows.Count -gt 0)
        & $applyView
        & $showView
        $exportBtn.IsEnabled = $script:rows.Count -gt 0
        $emptyState.Visibility = 'Collapsed'
        $when = try { ([datetime]$Scan.Timestamp).ToString('MMM d, HH:mm') } catch { "$($Scan.Timestamp)" }
        $status.Text = "Cached scan of '$($Scan.ScopeLabel)' from $when - $($Scan.RouteCount) route(s), $($Scan.OversharedCount) overshared. Click Scan for live data."
    }
    # Shared (non-closure) click handler for Recent-menu items - the item's Tag
    # carries the parsed scan object, or the '__clear__' sentinel.
    # --- saved reports -------------------------------------------------------
    # A "report" is the exported HTML/CSV document (distinct from a saved scan,
    # which is reloadable row data). On export we ALSO keep a managed copy under
    # the roaming profile + a .meta.json sidecar, so the Reports view can list and
    # re-open them reliably even if the user saved the original elsewhere.
    $script:reportsDir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'UserAccessExplorer\reports'
    $saveReport = {
        param($SourcePath, $User, $UserDisplay, $ScopeLabel, $Target, $Format, $RouteCount)
        try {
            if (-not (Test-Path $script:reportsDir)) { New-Item -ItemType Directory -Path $script:reportsDir -Force | Out-Null }
            $ext  = [System.IO.Path]::GetExtension($SourcePath)
            $base = [Guid]::NewGuid().ToString('N')
            $dest = Join-Path $script:reportsDir "$base$ext"
            Copy-Item -Path $SourcePath -Destination $dest -Force
            [pscustomobject]@{
                User = "$User"; UserDisplay = "$UserDisplay"; ScopeLabel = "$ScopeLabel"; Target = "$Target"; Format = "$Format"
                RouteCount = [int]$RouteCount; Timestamp = (Get-Date).ToString('o'); File = "$dest"; OriginalPath = "$SourcePath"
            } | ConvertTo-Json | Set-Content -Path (Join-Path $script:reportsDir "$base.meta.json") -Encoding UTF8
            $metas = @(Get-ChildItem $script:reportsDir -Filter *.meta.json -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            if ($metas.Count -gt 25) {
                $metas | Select-Object -Skip 25 | ForEach-Object {
                    try { $m = Get-Content $_.FullName -Raw | ConvertFrom-Json; if ($m.File -and (Test-Path $m.File)) { Remove-Item $m.File -Force -ErrorAction SilentlyContinue } } catch { Write-Verbose "prune report file skipped: $($_.Exception.Message)" }
                    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        } catch { Write-Verbose "save report skipped: $($_.Exception.Message)" }
    }
    $listReports = {
        if (-not (Test-Path $script:reportsDir)) { return @() }
        @(Get-ChildItem $script:reportsDir -Filter *.meta.json -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | ForEach-Object {
                try {
                    $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
                    $w = try { ([datetime]$j.Timestamp).ToString('MMM d, yyyy  HH:mm') } catch { "$($j.Timestamp)" }
                    $j | Add-Member -NotePropertyName When         -NotePropertyValue $w                                    -Force
                    $j | Add-Member -NotePropertyName ScopeDisplay -NotePropertyValue (& $scopeDisplayFor $j.ScopeLabel $j.Target) -Force
                    $j | Add-Member -NotePropertyName TargetUrl    -NotePropertyValue $(if ("$($j.ScopeLabel)" -eq 'Whole tenant') { 'All sites in the tenant' } elseif ("$($j.Target)") { "$($j.Target)" } else { '' }) -Force
                    $j | Add-Member -NotePropertyName _MetaPath    -NotePropertyValue $_.FullName                           -Force
                    $j
                } catch { Write-Verbose "skipped unreadable report meta: $($_.Exception.Message)" }
            })
    }
    $refreshReports = {
        $reports = @(& $listReports)
        $reportsList.ItemsSource = $reports
        $reportsEmpty.Visibility = if ($reports.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    }

    # Populate the One-site picker once, in the background, so choosing a site is
    # a selection rather than a URL to type. Kicked off on connect and again if
    # the user switches to One site before it has loaded.
    $script:siteLoaded = $false
    $loadSites = {
        if ($script:siteLoaded -or -not $script:clientId) { return }
        $status.Text = 'Loading site list...'
        $script:siteRs = [runspacefactory]::CreateRunspace(); $script:siteRs.Open()
        $script:sitePs = [powershell]::Create(); $script:sitePs.Runspace = $script:siteRs
        [void]$script:sitePs.AddScript($script:SiteEnumBlock).
            AddArgument($script:ModulePath).AddArgument($script:clientId).AddArgument($script:adminUrl)
        $script:siteOut = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
        $sinbuf = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
        $script:siteHandle = $script:sitePs.BeginInvoke($sinbuf, $script:siteOut)

        $script:siteTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:siteTimer.Interval = [TimeSpan]::FromMilliseconds(400)
        $script:siteTimer.Add_Tick({
            if (-not $script:siteHandle.IsCompleted) { return }
            $script:siteTimer.Stop()
            $err = $null
            try { $null = $script:sitePs.EndInvoke($script:siteHandle) } catch { $err = $_.Exception.Message }
            $sites = @($script:siteOut | ForEach-Object { [pscustomobject]@{ Display = "$($_.Title) - $($_.Url)"; Url = "$($_.Url)" } } | Sort-Object Display)
            $script:sitePs.Dispose(); $script:siteRs.Dispose()
            if ($sites.Count -gt 0) {
                $siteCombo.ItemsSource = $sites
                $script:siteLoaded = $true
                if ("$($status.Text)" -like 'Loading site list*') { $status.Text = "$($sites.Count) site(s) available - pick one or search." }
            } elseif ($err) { $status.Text = "Could not load sites: $err" }
        })
        $script:siteTimer.Start()
    }

    # placeholders
    $ph = {
        param($box, $place) $place.Visibility = if ("$($box.Text)".Length -eq 0) { 'Visible' } else { 'Collapsed' }
    }
    $userCombo.Add_SelectionChanged({ & $ph $userCombo $userPlace })
    $userCombo.Add_LostKeyboardFocus({ & $ph $userCombo $userPlace })
    $siteCombo.Add_SelectionChanged({ & $ph $siteCombo $sitePlace })
    $siteCombo.Add_KeyUp({ & $ph $siteCombo $sitePlace })
    $siteCombo.Add_LostKeyboardFocus({ & $ph $siteCombo $sitePlace })
    $filterBox.Add_TextChanged({ & $ph $filterBox $filterPlace; & $applyView })

    # scope combo shows/hides the site row and kicks off the site list
    $scopeCombo.Add_SelectionChanged({
        if ($scopeCombo.SelectedIndex -ge 1) { $siteRow.Visibility = 'Visible'; & $loadSites; $siteCombo.Focus() }
        else { $siteRow.Visibility = 'Collapsed' }
    })

    # --- settings popup (built in code so the connect flow lives here) --------
    $popup = New-Object System.Windows.Controls.Primitives.Popup
    $popup.PlacementTarget = $settingsBtn
    $popup.Placement = 'Bottom'; $popup.StaysOpen = $false; $popup.AllowsTransparency = $true
    $panelXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="{DynamicResource Surface}" CornerRadius="8" BorderBrush="{DynamicResource FieldBorder}" BorderThickness="1" Width="360" Margin="8">
  <Border.Effect><DropShadowEffect BlurRadius="16" ShadowDepth="2" Opacity="0.2"/></Border.Effect>
  <StackPanel Margin="16">
    <TextBlock Text="Connect to your tenant" FontWeight="SemiBold" FontSize="14" Foreground="{DynamicResource Ink}" Margin="0,0,0,10"/>
    <TextBlock Text="Client ID" FontSize="12" Foreground="{DynamicResource Subtle}" Margin="0,0,0,3"/>
    <ComboBox x:Name="PClient" Height="36" IsEditable="True" IsTextSearchEnabled="True" StaysOpenOnEdit="True" VerticalContentAlignment="Center"/>
    <TextBlock Text="Tenant admin URL" FontSize="12" Foreground="{DynamicResource Subtle}" Margin="0,10,0,3"/>
    <ComboBox x:Name="PAdmin" Height="36" IsEditable="True" IsTextSearchEnabled="True" StaysOpenOnEdit="True" VerticalContentAlignment="Center"/>
    <Button x:Name="PConnect" Content="Connect" Height="34" Margin="0,14,0,0" Background="{DynamicResource Accent}" Foreground="White" FontWeight="SemiBold" BorderThickness="0" Cursor="Hand"/>
    <TextBlock x:Name="PStatus" FontSize="11.5" Foreground="{DynamicResource Subtle}" Margin="0,8,0,0" TextWrapping="Wrap"/>
    <TextBlock Margin="0,10,0,0" FontSize="11.5" TextWrapping="Wrap">
      <Hyperlink x:Name="PRegister" Foreground="{DynamicResource Accent}">No app yet? Register one for this tenant</Hyperlink>
    </TextBlock>
  </StackPanel>
</Border>
'@
    $preader = New-Object System.Xml.XmlNodeReader ([xml]$panelXaml)
    $panel = [Windows.Markup.XamlReader]::Load($preader)
    $popup.Child = $panel
    $pClient = $panel.FindName('PClient'); $pAdmin = $panel.FindName('PAdmin')
    $pConnect = $panel.FindName('PConnect'); $pStatus = $panel.FindName('PStatus')
    $pRegister = $panel.FindName('PRegister')

    # The popup is loaded as its OWN tree, so its DynamicResource refs can't see
    # the window's brushes by default - share the window's resource dictionary so
    # the popup themes (and follows a live dark/light swap), and give its two
    # editable combos the themed template instead of the native white edit field.
    $panel.Resources.MergedDictionaries.Add($window.Resources)
    $pClient.Style = $window.Resources['FieldCombo']
    $pAdmin.Style  = $window.Resources['FieldCombo']

    # --- About panel + version / update check --------------------------------
    $aboutPopup = New-Object System.Windows.Controls.Primitives.Popup
    $aboutPopup.PlacementTarget = $versionButton
    $aboutPopup.Placement = 'Top'; $aboutPopup.StaysOpen = $false; $aboutPopup.AllowsTransparency = $true
    $aboutXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="{DynamicResource Surface}" CornerRadius="8" BorderBrush="{DynamicResource FieldBorder}" BorderThickness="1" Width="300" Margin="8">
  <Border.Effect><DropShadowEffect BlurRadius="16" ShadowDepth="2" Opacity="0.2"/></Border.Effect>
  <StackPanel Margin="18">
    <StackPanel>
      <TextBlock Text="User Access Explorer" FontWeight="SemiBold" FontSize="14.5" Foreground="{DynamicResource Ink}"/>
      <TextBlock x:Name="AboutVersion" Text="Version 0.0.0" FontSize="11.5" Foreground="{DynamicResource Subtle}" Margin="0,1,0,0"/>
    </StackPanel>
    <TextBlock Text="See what a user can reach across SharePoint &#8211; and where it's overshared." FontSize="11.5" Foreground="{DynamicResource Subtle}" TextWrapping="Wrap" Margin="0,12,0,0"/>
    <Border Height="1" Background="{DynamicResource Line}" Margin="0,14,0,0"/>
    <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
      <TextBlock x:Name="AboutStatusIcon" Text="&#xE895;" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="{DynamicResource Subtle}" VerticalAlignment="Top" Margin="0,1,8,0"/>
      <TextBlock x:Name="AboutStatus" Text="Check for the latest version." FontSize="12" Foreground="{DynamicResource Subtle}" VerticalAlignment="Center" TextWrapping="Wrap" MaxWidth="222"/>
    </StackPanel>
    <Button x:Name="AboutDownload" Content="Download update" Height="34" Margin="0,14,0,0" Background="{DynamicResource Accent}" Foreground="White" FontWeight="SemiBold" BorderThickness="0" Cursor="Hand" Visibility="Collapsed"/>
    <Button x:Name="AboutCheck" Content="Check for updates" Height="34" Margin="0,10,0,0" Cursor="Hand"/>
    <Border Height="1" Background="{DynamicResource Line}" Margin="0,16,0,0"/>
    <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
      <TextBlock Text="&#xE82D;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="{DynamicResource Accent}" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <TextBlock FontSize="11.5" VerticalAlignment="Center"><Hyperlink x:Name="AboutGuide" Foreground="{DynamicResource Accent}" TextDecorations="None">Guide &#38; how-to (fivenumber.com)</Hyperlink></TextBlock>
    </StackPanel>
    <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
      <TextBlock Text="&#xE71B;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="{DynamicResource Accent}" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <TextBlock FontSize="11.5" VerticalAlignment="Center"><Hyperlink x:Name="AboutRepo" Foreground="{DynamicResource Accent}" TextDecorations="None">View on GitHub</Hyperlink></TextBlock>
    </StackPanel>
  </StackPanel>
</Border>
'@
    $aboutPanel = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$aboutXaml)))
    $aboutPopup.Child = $aboutPanel
    $aboutPanel.Resources.MergedDictionaries.Add($window.Resources)
    $aboutVersion = $aboutPanel.FindName('AboutVersion'); $aboutStatus = $aboutPanel.FindName('AboutStatus'); $aboutStatusIcon = $aboutPanel.FindName('AboutStatusIcon')
    $aboutCheck = $aboutPanel.FindName('AboutCheck'); $aboutDownload = $aboutPanel.FindName('AboutDownload')
    $aboutRepo = $aboutPanel.FindName('AboutRepo'); $aboutGuide = $aboutPanel.FindName('AboutGuide')
    $aboutCheck.Style = $window.Resources['Secondary']
    $aboutVersion.Text = "Version $($script:appVersion)"

    # persist last-check time + result in a small file (so the badge survives a
    # restart without re-hitting the API, and we can throttle to once/day)
    $script:updateStatePath = Join-Path (Split-Path $script:settingsPath -Parent) 'update.json'
    $loadUpdateState = { try { if (Test-Path $script:updateStatePath) { return Get-Content $script:updateStatePath -Raw | ConvertFrom-Json } } catch { Write-Verbose "update state load skipped: $($_.Exception.Message)" } return $null }
    $saveUpdateState = {
        param($res)
        try {
            $dir = Split-Path $script:updateStatePath -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [pscustomobject]@{ LastCheck = (Get-Date).ToString('o'); Latest = $(if ($res) { "$($res.Latest)" }); Url = $(if ($res) { "$($res.Url)" }); Newer = $(if ($res) { [bool]$res.Newer } else { $false }) } |
                ConvertTo-Json | Set-Content -Path $script:updateStatePath -Encoding UTF8
        } catch { Write-Verbose "update state save skipped: $($_.Exception.Message)" }
    }

    $script:updateUrl = $null; $script:updChecking = $false
    # push a check result onto the UI (footer badge + About status)
    $applyUpdateResult = {
        param($res, $manual)
        if (-not $res -or -not $res.Latest) {
            if ($manual) {
                if ("$($res.Status)" -eq 'norelease') {
                    # reached GitHub fine, there just aren't any releases yet
                    $aboutStatusIcon.Text = [char]0xE73E; $aboutStatusIcon.Foreground = $window.Resources['GrantedPillFg']
                    $aboutStatus.Text = "You're on the current version (no releases published yet)."
                    $aboutStatus.Foreground = $window.Resources['Subtle']
                } else {
                    $aboutStatusIcon.Text = [char]0xE946; $aboutStatusIcon.Foreground = $window.Resources['Subtle']
                    $aboutStatus.Text = "Couldn't reach GitHub - you may be offline or behind a firewall."
                    $aboutStatus.Foreground = $window.Resources['Subtle']
                }
            }
            return
        }
        if ($res.Newer) {
            $script:updateUrl = "$($res.Url)"
            $updateBadge.Visibility = 'Visible'
            $aboutDownload.Visibility = 'Visible'
            $aboutStatusIcon.Text = [char]0xE7BA; $aboutStatusIcon.Foreground = $window.Resources['Accent']
            $aboutStatus.Text = "Update available: v$($res.Latest)"
            $aboutStatus.Foreground = $window.Resources['Accent']
        } else {
            $updateBadge.Visibility = 'Collapsed'
            $aboutDownload.Visibility = 'Collapsed'
            $aboutStatusIcon.Text = [char]0xE73E; $aboutStatusIcon.Foreground = $window.Resources['GrantedPillFg']
            $aboutStatus.Text = "You're on the latest version."
            $aboutStatus.Foreground = $window.Resources['Subtle']
        }
    }

    # the actual check runs in a background runspace (non-blocking, fail-silent);
    # GitHub Releases API needs a User-Agent header or it 403s.
    $script:UpdateBlock = {
        param($CurrentVersion, $Repo)
        try {
            $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'UserAccessExplorer'; 'Accept' = 'application/vnd.github+json' } -TimeoutSec 6
            $tag = "$($r.tag_name)" -replace '^[vV]', ''
            $newer = $false; try { $newer = ([version]$tag -gt [version]$CurrentVersion) } catch { $newer = $false }
            [pscustomobject]@{ Latest = $tag; Newer = $newer; Url = "$($r.html_url)"; Status = 'ok' }
        } catch {
            # 404 = the repo simply has no releases yet (not a failure) - the user
            # is on the current version. Anything else = a real network/firewall issue.
            $code = $null; try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = $null }
            [pscustomobject]@{ Latest = $null; Newer = $false; Url = $null; Status = $(if ($code -eq 404) { 'norelease' } else { 'error' }) }
        }
    }
    $runUpdateCheck = {
        param($manual)
        if ($script:updChecking) { return }
        $script:updChecking = $true
        if ($manual) { $aboutStatusIcon.Text = [char]0xE895; $aboutStatusIcon.Foreground = $window.Resources['Subtle']; $aboutStatus.Text = 'Checking for updates...'; $aboutStatus.Foreground = $window.Resources['Subtle'] }
        $script:updManual = [bool]$manual
        $script:updRs = [runspacefactory]::CreateRunspace(); $script:updRs.Open()
        $script:updPs = [powershell]::Create(); $script:updPs.Runspace = $script:updRs
        [void]$script:updPs.AddScript($script:UpdateBlock).AddArgument($script:appVersion).AddArgument($script:repo)
        $script:updOut = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
        $script:updHandle = $script:updPs.BeginInvoke($script:updOut, $script:updOut)
        $script:updTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:updTimer.Interval = [TimeSpan]::FromMilliseconds(400)
        $script:updTimer.Add_Tick({
            if (-not $script:updHandle.IsCompleted) { return }
            $script:updTimer.Stop()
            try { $null = $script:updPs.EndInvoke($script:updHandle) } catch { Write-Verbose "$_" }
            $res = @($script:updOut)[0]
            $script:updPs.Dispose(); $script:updRs.Dispose()
            $script:updChecking = $false
            & $applyUpdateResult $res $script:updManual
            & $saveUpdateState $res
        })
        $script:updTimer.Start()
    }

    $versionButton.Add_Click({ $aboutPopup.IsOpen = -not $aboutPopup.IsOpen })
    $aboutCheck.Add_Click({ & $runUpdateCheck $true })
    $aboutDownload.Add_Click({ if ($script:updateUrl) { try { Start-Process $script:updateUrl } catch { Write-Verbose "$_" } } })
    $aboutRepo.Add_Click({ try { Start-Process "https://github.com/$($script:repo)" } catch { Write-Verbose "$_" } })
    $aboutGuide.Add_Click({ try { Start-Process $script:guideUrl } catch { Write-Verbose "$_" } })

    # fill the dropdowns with the remembered history; pre-select the most recent
    $saved = & $loadSettings
    if ($saved) {
        $clientHist = @(@($saved.ClientIds) + @($saved.ClientId) | Where-Object { $_ })
        $adminHist  = @(@($saved.AdminUrls) + @($saved.AdminUrl)  | Where-Object { $_ })
        if ($clientHist.Count) { $pClient.ItemsSource = $clientHist; $pClient.SelectedIndex = 0 }
        if ($adminHist.Count)  { $pAdmin.ItemsSource  = $adminHist;  $pAdmin.SelectedIndex = 0 }
    }

    $settingsBtn.Add_Click({ $popup.IsOpen = -not $popup.IsOpen })

    # --- left-rail navigation -------------------------------------------------
    $refreshSaved = {
        $scans = @(& $listScans)
        $savedList.ItemsSource = $scans
        $savedEmpty.Visibility = if ($scans.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    }
    # collapse/expand the rail to an icon-only strip (labels hide via NavTextVis)
    $script:railCollapsed = $false
    $railToggle.Add_Click({
        $script:railCollapsed = -not $script:railCollapsed
        if ($script:railCollapsed) {
            $railBorder.Width = 56; $railDock.Margin = [System.Windows.Thickness]::new(8, 16, 8, 16)
            $window.Resources['NavTextVis'] = [System.Windows.Visibility]::Collapsed
        } else {
            $railBorder.Width = 208; $railDock.Margin = [System.Windows.Thickness]::new(14, 16, 14, 16)
            $window.Resources['NavTextVis'] = [System.Windows.Visibility]::Visible
        }
    })

    $navScan.Add_Checked({ $scanView.Visibility = 'Visible'; $savedView.Visibility = 'Collapsed'; $reportsView.Visibility = 'Collapsed' })
    $navSaved.Add_Checked({ & $refreshSaved; $savedView.Visibility = 'Visible'; $scanView.Visibility = 'Collapsed'; $reportsView.Visibility = 'Collapsed' })
    $navReports.Add_Checked({ & $refreshReports; $reportsView.Visibility = 'Visible'; $scanView.Visibility = 'Collapsed'; $savedView.Visibility = 'Collapsed' })

    # --- light / dark theme ---------------------------------------------------
    # Themeable brushes are DynamicResource; swapping the resource values repaints
    # the whole UI. Only structural surfaces switch - accents (blue) and risk
    # colours (red/green) are brand/semantic and read on both themes.
    $applyTheme = {
        param($dark)
        $script:darkMode = [bool]$dark
        $pal = if ($dark) {
            @{ Canvas = '#17171A'; Surface = '#232327'; RailBg = '#1D1D21'; Ink = '#ECECEE'; Subtle = '#9AA0A6'; Line = '#35353B'; TileBg = '#2A2A30'; FieldBorder = '#45454C'
               RowBg = '#232327'; SelBg = '#2C3A4D'; OversharedRow = '#3A2A2E'; IconBlue = '#1E2A3A'; IconRed = '#3A2429'; IconGreen = '#1F3328'; IconPurple = '#2C2440'
               TileOversharedBg = '#3A2429'; TileDanger = '#F19AA3'
               FieldDisabled = '#2A2A30'; BtnDisabledBg = '#2E2E34'; BtnDisabledFg = '#6B6B73'
               OversharedPillBg = '#3A2429'; OversharedPillFg = '#F19AA3'; GrantedPillBg = '#22331F'; GrantedPillFg = '#86CF95'
               Hover = '#2E2E34'; NavActive = '#263141' }
        } else {
            @{ Canvas = '#EEF0F3'; Surface = '#FFFFFF'; RailBg = '#F4F6F8'; Ink = '#242424'; Subtle = '#707882'; Line = '#E6E8EB'; TileBg = '#F7F8FA'; FieldBorder = '#C9CDD2'
               RowBg = '#FFFFFF'; SelBg = '#E9F1FB'; OversharedRow = '#FDF3F2'; IconBlue = '#E7F0FB'; IconRed = '#FBE3E6'; IconGreen = '#E7F3EC'; IconPurple = '#EFE9F5'
               TileOversharedBg = '#FCE7EA'; TileDanger = '#B10E1C'
               FieldDisabled = '#F2F3F5'; BtnDisabledBg = '#E4E6E9'; BtnDisabledFg = '#A6ABB2'
               OversharedPillBg = '#FCE7EA'; OversharedPillFg = '#B10E1C'; GrantedPillBg = '#EAF1E7'; GrantedPillFg = '#107C41'
               Hover = '#EDEFF2'; NavActive = '#E7F0FB' }
        }
        foreach ($k in @($pal.Keys)) {
            $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($pal[$k]))
            $b.Freeze()
            # Cast to [Brush] so the RAW .NET brush is stored. The ResourceDictionary
            # indexer is typed 'object', so an uncast assignment keeps PowerShell's
            # PSObject wrapper and WPF then fails: "cannot cast PSObject to Brush".
            $window.Resources[$k] = [System.Windows.Media.Brush]$b
        }
        $window.Background = [System.Windows.Media.Brush]$window.Resources['Canvas']
        $themeToggle.Content = if ($dark) { 'Light mode' } else { 'Dark mode' }
        $themeToggle.Tag = if ($dark) { [char]0xE706 } else { [char]0xE708 }
        if ($script:rows -and $script:rows.Count -gt 0) { & $refreshTiles $script:rows }  # reapply the code-set tile brushes
    }
    $themeToggle.Add_Click({ & $applyTheme (-not $script:darkMode); & $saveSettings $script:clientId $script:adminUrl })

    # Open / Delete buttons live inside the Saved-scans item template; one shared
    # handler reads the clicked button's DataContext (the scan object).
    $savedList.AddHandler(
        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [System.Windows.RoutedEventHandler]{
            $node = $args[1].OriginalSource
            while ($node) {
                if ($node -is [System.Windows.Controls.Button] -and $node.Name -eq 'OpenScanBtn') {
                    $scan = $node.DataContext
                    if ($scan) { & $loadScan $scan; $navScan.IsChecked = $true }
                    break
                }
                if ($node -is [System.Windows.Controls.Button] -and $node.Name -eq 'DelScanBtn') {
                    $scan = $node.DataContext
                    if ($scan -and $scan._Path) {
                        try { Remove-Item $scan._Path -Force -ErrorAction SilentlyContinue } catch { Write-Verbose "delete scan skipped: $($_.Exception.Message)" }
                        & $refreshSaved
                    }
                    break
                }
                $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
            }
        }
    )

    # Open / Delete for the Reports view (mirrors the Saved-scans handler).
    $reportsList.AddHandler(
        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [System.Windows.RoutedEventHandler]{
            $node = $args[1].OriginalSource
            while ($node) {
                if ($node -is [System.Windows.Controls.Button] -and $node.Name -eq 'OpenReportBtn') {
                    $rep = $node.DataContext
                    $target = if ($rep.File -and (Test-Path $rep.File)) { $rep.File } else { $rep.OriginalPath }
                    if ($target) { try { Start-Process $target } catch { $status.Text = "Could not open the report: $($_.Exception.Message)" } }
                    break
                }
                if ($node -is [System.Windows.Controls.Button] -and $node.Name -eq 'DelReportBtn') {
                    $rep = $node.DataContext
                    if ($rep) {
                        try {
                            if ($rep.File -and (Test-Path $rep.File)) { Remove-Item $rep.File -Force -ErrorAction SilentlyContinue }
                            if ($rep._MetaPath -and (Test-Path $rep._MetaPath)) { Remove-Item $rep._MetaPath -Force -ErrorAction SilentlyContinue }
                        } catch { Write-Verbose "delete report skipped: $($_.Exception.Message)" }
                        & $refreshReports
                    }
                    break
                }
                $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
            }
        }
    )

    $pConnect.Add_Click({
        $c = "$($pClient.Text)".Trim(); $a = "$($pAdmin.Text)".Trim()
        if (-not $c -or -not $a) { $pStatus.Text = 'Enter both Client ID and Tenant admin URL.'; return }
        $pStatus.Text = 'Connecting... a sign-in window will appear.'
        try {
            Connect-PnPOnline -Url $a -ClientId $c -Interactive
            $script:clientId = $c; $script:adminUrl = $a
            & $saveSettings $c $a
            $tenant = if ($a -match 'https://([^.\-]+)') { $matches[1] } else { 'tenant' }
            $chipText.Text = $tenant; $chipText.Foreground = $brGreen
            $chipIcon.Text = [char]0xE73E; $chipIcon.Foreground = $brGreen
            $tenantChip.Background = $riskBgE
            $userCombo.IsEnabled = $true; $scanBtn.IsEnabled = $true
            & $loadSites
            $status.Text = 'Connected. Type a name or email in the User box, then Scan.'
            $pStatus.Text = "Connected to $tenant."
            $popup.IsOpen = $false
        } catch { $pStatus.Text = "Connect failed: $($_.Exception.Message)" }
    })

    # First-run helper: create an Entra app for this tenant and fill in the ID.
    # PnP has a cmdlet for exactly this, so users do not have to click through
    # the Entra portal. Runs interactively (browser consent), like Connect.
    $pRegister.Add_Click({
        $a = "$($pAdmin.Text)".Trim()
        $tenantName = if ($a -match 'https://([^.\-]+)') { $matches[1] } else { $null }
        if (-not $tenantName) { $pStatus.Text = 'Enter the Tenant admin URL first - it tells me your tenant.'; return }
        $tenant = "$tenantName.onmicrosoft.com"
        $pStatus.Text = "Registering an app in $tenant... sign in and consent when prompted."
        try {
            $app = Register-PnPEntraIDAppForInteractiveLogin -ApplicationName 'User Access Explorer' -Tenant $tenant -Interactive
            $cid = $null
            foreach ($p in 'AzureAppId','ClientId','AppId','Id') {
                if ($app -and ($app.PSObject.Properties.Name -contains $p) -and $app.$p) { $cid = "$($app.$p)"; break }
            }
            if (-not $cid) {
                $m = [regex]::Match("$app", '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
                if ($m.Success) { $cid = $m.Value }
            }
            if ($cid) { $pClient.Text = $cid; $pStatus.Text = 'App registered. Client ID filled in - now click Connect.' }
            else { $pStatus.Text = 'App registered, but I could not read the Client ID - check the Entra portal.' }
        } catch { $pStatus.Text = "Register failed: $($_.Exception.Message)" }
    })

    # --- user search-as-you-type (debounced), shared by both user pickers -----
    $searchUsersInto = {
        param($combo)
        $term = "$($combo.Text)".Trim()
        if ($term.Length -lt 2) {
            if ($term.Length -ge 1) { $status.Text = 'Keep typing - at least 2 letters to search for a user.' }
            return
        }
        if ($combo.SelectedItem -and $combo.SelectedItem.Display -eq $term) { return }
        try {
            $cap = 25; $esc = $term.Replace("'", "''")
            $byName = (Invoke-PnPGraphMethod -Url "users?`$filter=startswith(displayName,'$esc')&`$select=displayName,userPrincipalName&`$top=$cap" -Method Get).value
            $byUpn  = (Invoke-PnPGraphMethod -Url "users?`$filter=startswith(userPrincipalName,'$esc')&`$select=displayName,userPrincipalName&`$top=$cap" -Method Get).value
            $seen = @{}
            $items = foreach ($u in @($byName) + @($byUpn)) {
                if (-not $u -or $seen.ContainsKey($u.userPrincipalName)) { continue }
                $seen[$u.userPrincipalName] = $true
                [pscustomobject]@{ Display = "$($u.displayName) - $($u.userPrincipalName)"; Upn = $u.userPrincipalName }
            }
            $items = @($items | Sort-Object Display)
            $combo.ItemsSource = $items
            $combo.IsDropDownOpen = ($items.Count -gt 0)
            $status.Text = if ($items.Count) { "$($items.Count) match(es). Pick one, then Scan." } else { "No users start with '$term'." }
        } catch {
            $m = "$($_.Exception.Message)"
            if ($m -match 'Authorization_RequestDenied|Forbidden|403|does not have permission|insufficient|Access.?denied') {
                $status.Text = "User search needs the Graph User.ReadBasic.All permission consented for this app. You can still type the full email address and click Scan."
            } else {
                $status.Text = "Search failed: $m"
            }
        }
    }
    $script:searchTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:searchTimer.Interval = [TimeSpan]::FromMilliseconds(450)
    $script:searchTimer.Add_Tick({ $script:searchTimer.Stop(); & $searchUsersInto $userCombo })
    $script:searchTimerB = New-Object System.Windows.Threading.DispatcherTimer
    $script:searchTimerB.Interval = [TimeSpan]::FromMilliseconds(450)
    $script:searchTimerB.Add_Tick({ $script:searchTimerB.Stop(); & $searchUsersInto $userComboB })
    $userCombo.Add_KeyUp({
        & $ph $userCombo $userPlace
        if ("$($args[1].Key)" -in 'Down','Up','Enter','Tab','Escape','Left','Right') { return }
        $script:searchTimer.Stop(); $script:searchTimer.Start()
    })
    $userComboB.Add_KeyUp({
        & $ph $userComboB $userPlaceB
        if ("$($args[1].Key)" -in 'Down','Up','Enter','Tab','Escape','Left','Right') { return }
        $script:searchTimerB.Stop(); $script:searchTimerB.Start()
    })
    $userComboB.Add_SelectionChanged({ & $ph $userComboB $userPlaceB })
    $userComboB.Add_LostKeyboardFocus({ & $ph $userComboB $userPlaceB })

    # "Compare two users" reveals the second user picker; toggle the link text
    $script:compareMode = $false
    $compareLink.Add_Click({
        $script:compareMode = -not $script:compareMode
        $userRowB.Visibility = if ($script:compareMode) { 'Visible' } else { 'Collapsed' }
        $compareLink.Inlines.Clear()
        [void]$compareLink.Inlines.Add($(if ($script:compareMode) { 'Single user' } else { 'Compare two users' }))
    })

    # --- export --------------------------------------------------------------
    $exportBtn.Add_Click({
        $flat = if ($script:rows) { $script:rows.ToArray() } else { @() }
        if (-not $flat -or $flat.Count -eq 0) { $status.Text = 'Nothing to export - run a scan first.'; return }
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter = 'HTML report (*.html)|*.html|CSV (*.csv)|*.csv'; $dlg.FileName = 'access-report.html'
        if ($dlg.ShowDialog()) {
            try {
                $fmt = if ($dlg.FileName -match '\.csv$') { 'CSV' } else { 'HTML' }
                if ($fmt -eq 'CSV') { $flat | Export-UserAccessReport -Path $dlg.FileName | Out-Null }
                else { $flat | Export-UserAccessReport -Path $dlg.FileName -Html | Out-Null }
                # keep a managed copy so it shows in the Reports view
                & $saveReport $dlg.FileName $script:lastUser $script:lastUserDisplay $script:lastScopeLabel $script:lastTarget $fmt $flat.Count
                $status.Text = "Report saved to $($dlg.FileName) - also in Reports"
            } catch { $status.Text = "Export failed: $($_.Exception.Message)" }
        }
    })

    # --- scan ----------------------------------------------------------------
    $script:rows = $null; $script:bgPs = $null; $script:bgRs = $null
    $script:handle = $null; $script:output = $null; $script:seen = 0; $script:timer = $null; $script:cancelled = $false
    $script:lastMode = $null
    $script:lastUser = $null; $script:lastUserDisplay = $null; $script:lastTarget = $null; $script:lastScopeLabel = $null
    $script:isCompare = $false; $script:cmpUserA = ''; $script:cmpUserB = ''

    $stopBtn.Add_Click({
        if ($script:bgPs) { $script:cancelled = $true; try { $script:bgPs.Stop() } catch { Write-Verbose "$_" } ; $status.Text = 'Stopping...' }
    })

    $scanBtn.Add_Click({
        $selected = $userCombo.SelectedItem
        $user = if ($selected) { $selected.Upn }
                elseif ("$($userCombo.Text)" -match '@') { "$($userCombo.Text)".Trim() }
                else { $null }
        if (-not $user) { $status.Text = 'Pick a user from the search list first.'; return }

        # second user, only in Compare mode
        $userB = $null; $selectedB = $null
        if ($script:compareMode) {
            $selectedB = $userComboB.SelectedItem
            $userB = if ($selectedB) { $selectedB.Upn }
                     elseif ("$($userComboB.Text)" -match '@') { "$($userComboB.Text)".Trim() }
                     else { $null }
            if (-not $userB) { $status.Text = 'Compare mode: pick a second user as well.'; return }
        }
        # compare bookkeeping (set before the tiles reset so they read it)
        $script:isCompare = [bool]$userB
        $script:cmpUserA = if ($selected) { "$($selected.Display)" } else { "$user" }
        $script:cmpUserB = if ($userB) { if ($selectedB) { "$($selectedB.Display)" } else { "$userB" } } else { '' }

        $mode = switch ($scopeCombo.SelectedIndex) { 0 { 'Tenant' } 2 { 'Deep' } default { 'Site' } }
        $isTenant = ($mode -eq 'Tenant')
        $siteSel = $siteCombo.SelectedItem
        $target = if ($isTenant) { $script:adminUrl }
                  elseif ($siteSel) { "$($siteSel.Url)" }
                  else { "$($siteCombo.Text)".Trim() }
        if (-not $target) { $status.Text = if ($isTenant) { 'Connect first (settings).' } else { 'Pick a site.' }; return }

        $script:rows = New-Object System.Collections.Generic.List[object]
        $script:allRows = @(); $list.ItemsSource = [object[]]@()
        $script:seen = 0; $script:cancelled = $false
        # start both hidden; the grid appears once the first rows stream in
        # (applyView), the tree (deep only) is rendered on completion
        $resultsTree.Visibility = 'Collapsed'; $list.Visibility = 'Collapsed'
        & $refreshTiles @()
        $emptyState.Visibility = 'Collapsed'
        $scanBtn.IsEnabled = $false; $exportBtn.IsEnabled = $false
        $progress.Visibility = 'Visible'; $progress.IsIndeterminate = -not $isTenant; $progress.Value = 0
        $stopBtn.Visibility = 'Visible'
        $status.Text = if ($userB) { "Comparing two users - running both scans, this takes about twice as long..." } elseif ($mode -eq 'Deep') { "Deep scan of $target - walking subsites, lists and items. This can take a while..." } else { "Scanning $user..." }
        $scopeNote.Text = if ($userB) {
            "Comparing what each user can reach. Rows are grouped Shared by both / Only one user - the 'User' column shows whose access each route is."
        } elseif ($mode -eq 'Deep') {
            "Deep scan: sites, libraries, folders and items that have their OWN permissions (broken inheritance). Content that inherits is covered by the access shown above it - it is not listed item by item."
        } else {
            "Each row is a route that grants this user access to a site - the sites they can reach and how. Individual files are not listed; they inherit the site's access."
        }

        # The tree shows one site's Site > Library > Folder > Item hierarchy, so it
        # only applies to a deep scan. Hide it for tenant / site-level, and make it
        # the default view for deep - but only ONCE the scan finishes (set in the
        # completion handler). During the scan we keep IsChecked false so rows
        # stream visibly into the grid instead of a blank pane.
        # The Object and Location columns are deep-scan concepts too - they are
        # always empty for site-level rows - so hide them and give Site / Grant
        # path the room instead.
        $script:lastMode = $mode
        $script:lastUser = $user
        $script:lastUserDisplay = if ($selected) { "$($selected.Display)" } else { "$user" }
        $script:lastTarget = $target
        $script:lastScopeLabel = switch ($mode) { 'Tenant' { 'Whole tenant' } 'Deep' { 'One site (deep)' } default { 'One site' } }
        $colWho.Visibility = if ($userB) { 'Visible' } else { 'Collapsed' }
        # group by the comparison bucket in compare mode; clear it when leaving compare
        $script:groupField = if ($userB) { 'CompareStatus' } elseif ($script:groupField -eq 'CompareStatus') { $null } else { $script:groupField }
        if ($mode -eq 'Deep') {
            $viewToggle.Visibility = 'Visible'
            $colObject.Visibility = 'Visible'; $colLocation.Visibility = 'Visible'
        } else {
            $viewToggle.Visibility = 'Collapsed'
            $colObject.Visibility = 'Collapsed'; $colLocation.Visibility = 'Collapsed'
        }
        $viewToggle.IsChecked = $false

        $script:bgRs = [runspacefactory]::CreateRunspace(); $script:bgRs.Open()
        $script:bgPs = [powershell]::Create(); $script:bgPs.Runspace = $script:bgRs
        [void]$script:bgPs.AddScript($script:ScanBlock).
            AddArgument($script:ModulePath).AddArgument($user).AddArgument($script:clientId).
            AddArgument($target).AddArgument($mode).AddArgument($userB)

        $script:output = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
        $inbuf = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
        $script:handle = $script:bgPs.BeginInvoke($inbuf, $script:output)

        $script:timer = New-Object System.Windows.Threading.DispatcherTimer
        $script:timer.Interval = [TimeSpan]::FromMilliseconds(400)
        $script:timer.Add_Tick({
            $new = $false
            while ($script:output.Count -gt $script:seen) { $script:rows.Add($script:output[$script:seen]); $script:seen++; $new = $true }

            # determinate progress read straight from the scan's Write-Progress
            $pr = $script:bgPs.Streams.Progress
            if ($pr.Count -gt 0) {
                $last = $pr[$pr.Count - 1]
                if ($last.PercentComplete -ge 0) { $progress.Value = $last.PercentComplete }
                if ("$($last.StatusDescription)" -match '^(\d+) of (\d+)') { $status.Text = "Scanning site $($matches[1]) of $($matches[2])" }
            }

            if ($new) {
                $script:allRows = & $buildRows $script:rows
                & $refreshTiles $script:rows
                & $applyView
            }

            if ($script:handle.IsCompleted) {
                $script:timer.Stop()
                $failMsg = $null
                try { $null = $script:bgPs.EndInvoke($script:handle) } catch { if (-not $script:cancelled) { $failMsg = $_.Exception.Message } }
                foreach ($errRec in $script:bgPs.Streams.Error) { if (-not $script:cancelled) { $failMsg = "$errRec" } }
                $skipped = @($script:bgPs.Streams.Warning | Where-Object { "$_" -match '^Skipped ' }).Count
                $script:bgPs.Dispose(); $script:bgRs.Dispose()

                $script:allRows = & $buildRows $script:rows
                & $refreshTiles $script:rows
                & $applyView
                # deep results land in the tree; flip to it now that rows are in
                if ($script:lastMode -eq 'Deep' -and $script:rows.Count -gt 0) { $viewToggle.IsChecked = $true }
                & $showView
                $progress.Visibility = 'Collapsed'; $stopBtn.Visibility = 'Collapsed'
                $scanBtn.IsEnabled = $true; $exportBtn.IsEnabled = $script:rows.Count -gt 0

                # persist the completed scan so it can be reloaded instantly later
                # (compare runs aren't saved - reload has no compare view yet)
                if (-not $script:cancelled -and $script:rows.Count -gt 0 -and -not $script:isCompare) {
                    & $saveScan $script:lastUser $script:lastUserDisplay $script:lastMode $script:lastScopeLabel $script:lastTarget $script:rows
                }

                $u = @($script:rows | Where-Object { $_.RouteType -eq 'Overshared' }).Count
                $skipNote = if ($skipped) { " ($skipped site(s) skipped)" } else { "" }
                if ($script:cancelled) { $status.Text = "Stopped. $($script:rows.Count) route(s) collected, $u overshared." }
                elseif ($failMsg -and $script:rows.Count -eq 0) {
                    $emptyState.Text = "Scan failed: $failMsg"; $emptyState.Visibility = 'Visible'; $status.Text = "Failed: $failMsg"
                }
                elseif ($script:rows.Count -eq 0) {
                    $emptyState.Text = 'No access found - this user cannot reach the scanned scope.'; $emptyState.Visibility = 'Visible'
                    $status.Text = 'Done: no access found.'
                }
                else { $status.Text = "Done: $($script:rows.Count) route(s), $u overshared$skipNote." }
            }
        })
        $script:timer.Start()
    })

    # open settings on launch so the first thing a user sees is how to connect
    # restore the saved theme before the window paints
    $startSaved = & $loadSettings
    if ($startSaved -and ($startSaved.PSObject.Properties.Name -contains 'Theme') -and $startSaved.Theme) { & $applyTheme $true }

    # show any cached "update available" badge immediately, then refresh in the
    # background if the last check was > 24h ago (throttled, non-blocking, silent).
    $us = & $loadUpdateState
    if ($us) { & $applyUpdateResult ([pscustomobject]@{ Latest = $us.Latest; Newer = $us.Newer; Url = $us.Url }) $false }
    $stale = $true
    if ($us -and $us.LastCheck) { try { $stale = ((Get-Date) - [datetime]$us.LastCheck).TotalHours -ge 24 } catch { $stale = $true } }
    if ($stale) { & $runUpdateCheck $false }

    $window.Add_Loaded({ $popup.IsOpen = $true })
    $null = $window.ShowDialog()
}

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') {
    & $guiScript $moduleManifest
}
else {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($guiScript).AddArgument($moduleManifest)
    $ps.Invoke()
    foreach ($e in $ps.Streams.Error) { Write-Warning "GUI error: $e" }
    $ps.Dispose(); $rs.Close(); $rs.Dispose()
}
