### A Pluto.jl notebook ###
# v0.19.36

#> [frontmatter]
#> title = "Heart Segmentation"

using Markdown
using InteractiveUtils

# This Pluto notebook uses @bind for interactivity. When running this notebook outside of Pluto, the following 'mock version' of @bind gives bound variables a default value (instead of an error).
macro bind(def, element)
    quote
        local iv = try Base.loaded_modules[Base.PkgId(Base.UUID("6e696c72-6542-2067-7265-42206c756150"), "AbstractPlutoDingetjes")].Bonds.initial_value catch; b -> missing; end
        local el = $(esc(element))
        global $(esc(def)) = Core.applicable(Base.get, el) ? Base.get(el) : iv(el)
        el
    end
end

# ╔═╡ d4f7e164-f9a6-47ee-85a7-dd4e0dec10ee
# ╠═╡ show_logs = false
using Pkg; Pkg.activate(".."); Pkg.instantiate()

# ╔═╡ 8d4a6d5a-c437-43bb-a3db-ab961b218c2e
using PlutoUI: TableOfContents, Slider, bind

# ╔═╡ 83b95cee-90ed-4522-b9a8-79c082fce02e
using Random: default_rng, seed!

# ╔═╡ 7353b7ce-8b33-4602-aed7-2aa24864aca5
using HTTP: download

# ╔═╡ de5efc37-db19-440e-9487-9a7bea84996d
using Tar: extract

# ╔═╡ 3ab44a2a-692f-4603-a5a8-81f1d260c13e
using MLUtils: DataLoader, splitobs, mapobs, getobs

# ╔═╡ 562b3772-89cc-4390-87c3-e7260c8aa86b
using NIfTI: niread

# ╔═╡ db2ccf3a-437a-4dfa-ad05-2526c0e2bde0
using Glob: glob

# ╔═╡ 8e2f2c6d-127d-42a6-9906-970c09a22e61
using CairoMakie: Figure, Axis, heatmap!

# ╔═╡ 317c1571-d232-4cab-ac10-9fc3b7ad33b0
# ╠═╡ show_logs = false
using LuxCUDA

# ╔═╡ a3f44d7c-efa3-41d0-9509-b099ab7f09d4
using Lux

# ╔═╡ a6669580-de24-4111-a7cb-26d3e727a12e
using DistanceTransforms: transform, boolean_indicator

# ╔═╡ dfc9377a-7cc1-43ba-bb43-683d24e67d79
using ComputerVisionMetrics: hausdorff_metric, dice_metric

# ╔═╡ c283f9a3-6a76-4186-859f-21cd9efc131f
using ChainRulesCore: ignore_derivatives

# ╔═╡ c8d6553a-90df-4aeb-aa6d-a213e16fab48
TableOfContents()

# ╔═╡ af50e5f3-1a1c-47e5-a461-ffbee0329309
begin
    rng = default_rng()
    seed!(rng, 0)
end

# ╔═╡ cdfd2412-897d-4642-bb69-f8031c418446
function download_dataset(heart_url, target_directory)
    if isempty(readdir(target_directory))
        local_tar_file = joinpath(target_directory, "heart_dataset.tar")
		download(heart_url, "heart_dataset.tar")
		extract("heart_dataset.tar", target_directory)
		data_dir = joinpath(target_directory, readdir(target_directory)...)
        return data_dir
    else
        @warn "Target directory is not empty. Aborting download and extraction."
        return taget_directory
    end
end

# ╔═╡ b1516500-ad83-41d2-8a1d-093cd0d948e3
heart_url = "https://msd-for-monai.s3-us-west-2.amazonaws.com/Task02_Heart.tar"

# ╔═╡ 3e896957-61d8-4750-89bd-be02383417ec
target_directory = mktempdir()

# ╔═╡ 99211382-7de9-4e97-872f-d0c01b8f8307
# ╠═╡ show_logs = false
data_dir = download_dataset(heart_url, target_directory)

# ╔═╡ 6d34b756-4da8-427c-91f5-dfb022c4e715
begin
	struct ImageCASDataset
		image_paths::Vector{String}
		label_paths::Vector{String}
	end
	
	function ImageCASDataset(root_dir::String)
		image_paths = glob("*.nii*", joinpath(root_dir, "imagesTr"))
		label_paths = glob("*.nii*", joinpath(root_dir, "labelsTr"))
		return ImageCASDataset(image_paths, label_paths)
	end
	
	Base.length(d::ImageCASDataset) = length(d.image_paths)
	
	function Base.getindex(d::ImageCASDataset, i::Int)
	    image = niread(d.image_paths[i]).raw
	    label = niread(d.label_paths[i]).raw
	    return (image, label)
	end
	
	function Base.getindex(d::ImageCASDataset, idxs::AbstractVector{Int})
	    images = Vector{Array{Float32, 3}}(undef, length(idxs))
	    labels = Vector{Array{UInt8, 3}}(undef, length(idxs))
	    for (index, i) in enumerate(idxs)
	        images[index] = niread(d.image_paths[i]).raw
	        labels[index]  = niread(d.label_paths[i]).raw
	    end
	    return (images, labels)
	end

end

# ╔═╡ af798f6b-7549-4253-b02b-2ed20dc1125b
md"""
# Randomness
"""

# ╔═╡ f0e64ba5-5e11-4ddb-91d3-2a34c60dc6bf
md"""
# Data Preparation
"""

# ╔═╡ ec7734c3-33a5-43c7-82db-2db4dbdc9587
md"""
## Dataset
"""

# ╔═╡ 9577b91b-faa4-4fc5-9ec2-ed8ca94f2afe
data = ImageCASDataset(data_dir)

# ╔═╡ ae3d24e4-2216-4744-9093-0d2a8bbaae2d
md"""
## Preprocessing
"""

# ╔═╡ 18b31959-9cdf-41d9-a389-7c18febf7b07
function center_crop(volume::Array{T, 3}, target_size::Tuple{Int, Int, Int}) where {T}
    center = div.(size(volume), 2)

    start_idx = max.(1, center .- div.(target_size, 2))
    end_idx = start_idx .+ target_size .- 1

	cropped_volume = volume[start_idx[1]:end_idx[1], start_idx[2]:end_idx[2], start_idx[3]:end_idx[3]]
    return cropped_volume
end

# ╔═╡ 72827ad5-4820-4545-8099-1033d962970e
function one_hot_encode(label::Array{T, 3}, num_classes::Int) where {T}
	one_hot = zeros(T, size(label)..., num_classes)
	
    for k in 1:num_classes
        one_hot[:, :, :, k] = label .== k-1
    end
	
    return one_hot
end

# ╔═╡ 8ad7b2bb-1672-473a-a7b5-bf505733f7a3
function preprocess_image_label_pair(pair, target_size)
    # Check if pair[1] and pair[2] are individual arrays or collections of arrays
    is_individual = ndims(pair[1]) == 3 && ndims(pair[2]) == 3

    if is_individual
        # Handle a single pair
        cropped_image = center_crop(pair[1], target_size)
        cropped_label = one_hot_encode(center_crop(pair[2], target_size), 2)
        processed_image = reshape(cropped_image, size(cropped_image)..., 1)
        return (processed_image, cropped_label)
    else
        # Handle a batch of pairs
		cropped_images = [center_crop(img, target_size) for img in pair[1]]
		cropped_labels = [one_hot_encode(center_crop(lbl, target_size), 2) for lbl in pair[2]]
		processed_images = [reshape(img, size(img)..., 1) for img in cropped_images]
        return (processed_images, cropped_labels)
    end
end

# ╔═╡ ac2ed012-2b64-42b2-b97c-2a5352af9ec8
if LuxCUDA.functional()
	target_size = (128, 128, 64)
else
	target_size = (64, 64, 32)
end

# ╔═╡ c5539898-6b0c-4172-ba6c-9bfe2819c9fb
transformed_data = mapobs(
	x -> preprocess_image_label_pair(x, target_size),
	data
)

# ╔═╡ 03bab55a-6e5e-4b9f-b56a-7e9f993576eb
md"""
## Dataloaders
"""

# ╔═╡ d40f19dc-f06e-44ef-b82b-9763ff1f1189
train_indices, val_indices = splitobs(transformed_data; at = 0.75)

# ╔═╡ 4d75f114-225f-45e2-a683-e82ff137d909
bs = 4

# ╔═╡ 2032b7e6-ceb7-4c08-9b0d-bc704f5e4104
begin
	train_loader = DataLoader(train_indices; batchsize = bs, collate = true)
	val_loader = DataLoader(val_indices; batchsize = bs, collate = true)
end

# ╔═╡ 2ec43028-c1ab-4df7-9cfe-cc1a4919a7cf
md"""
# Data Visualization
"""

# ╔═╡ a6316144-c809-4d2a-bda1-d5128dcf89d3
md"""
## Original Data
"""

# ╔═╡ f8fc2cee-c1bd-477d-9595-9427e8764bd6
image_raw, label_raw = getobs(data, 1);

# ╔═╡ 7cb986f8-b338-4046-b569-493e443a8dcb
@bind z1 Slider(axes(image_raw, 3), show_value = true, default = div(size(image_raw, 3), 2))

# ╔═╡ d7e75a72-8281-432c-abab-c254f8c94d3c
let
	f = Figure(size = (700, 500))
	ax = Axis(
		f[1, 1],
		title = "Original Image"
	)
	heatmap!(image_raw[:, :, z1]; colormap = :grays)

	ax = Axis(
		f[1, 2],
		title = "Original Label (Overlayed)"
	)
	heatmap!(image_raw[:, :, z1]; colormap = :grays)
	heatmap!(label_raw[:, :, z1]; colormap = (:jet, 0.4))
	f
end

# ╔═╡ 9dc89870-3d99-472e-8974-712e34a3a789
md"""
## Transformed Data
"""

# ╔═╡ 0f5d7796-2c3d-4b74-86c1-a1d4e3922011
image_tfm, label_tfm = getobs(transformed_data, 1);

# ╔═╡ 6e2bfcfb-77e3-4532-a14d-10f4b91f2f54
@bind z2 Slider(1:target_size[3], show_value = true, default = div(target_size[3], 2))

# ╔═╡ bae79c05-034a-4c39-801a-01229b618e94
let
	f = Figure(size = (700, 500))
	ax = Axis(
		f[1, 1],
		title = "Transformed Image"
	)
	heatmap!(image_tfm[:, :, z2, 1]; colormap = :grays)

	ax = Axis(
		f[1, 2],
		title = "Transformed Label (Overlayed)"
	)
	heatmap!(image_tfm[:, :, z2, 1]; colormap = :grays)
	heatmap!(label_tfm[:, :, z2, 2]; colormap = (:jet, 0.4))
	f
end

# ╔═╡ 1494df6e-f407-42c4-8404-1f4871a2f817
md"""
# Model
"""

# ╔═╡ b3fc9578-6b40-4afc-bb58-c772a61a60a5
md"""
## Helper functions
"""

# ╔═╡ 3e938872-a390-40ba-8b00-b132f988e2d3
function create_unet_layers(
    kernel_size, de_kernel_size, channel_list;
    downsample = true)

    padding = (kernel_size - 1) ÷ 2

	conv1 = Conv((kernel_size, kernel_size, kernel_size), channel_list[1] => channel_list[2], stride=1, pad=padding)
	conv2 = Conv((kernel_size, kernel_size, kernel_size), channel_list[2] => channel_list[3], stride=1, pad=padding)

    relu1 = relu
    relu2 = relu
    bn1 = BatchNorm(channel_list[2])
    bn2 = BatchNorm(channel_list[3])

	bridge_conv = Conv((kernel_size, kernel_size, kernel_size), channel_list[1] => channel_list[3], stride=1, pad=padding)

    if downsample
        sample = Chain(
			Conv((de_kernel_size, de_kernel_size, de_kernel_size), channel_list[3] => channel_list[3], stride=2, pad=(de_kernel_size - 1) ÷ 2, dilation=1),
            BatchNorm(channel_list[3]),
            relu
        )
    else
        sample = Chain(
			ConvTranspose((de_kernel_size, de_kernel_size, de_kernel_size), channel_list[3] => channel_list[3], stride=2, pad=(de_kernel_size - 1) ÷ 2),
            BatchNorm(channel_list[3]),
            relu
        )
    end

    return (conv1, conv2, relu1, relu2, bn1, bn2, bridge_conv, sample)
end

# ╔═╡ 1d65b1d1-82de-40ca-aaba-9eee23883cf3
md"""
## Contracting Block
"""

# ╔═╡ 40762509-b26e-47f5-8b49-e7100fdeb72a
begin
    struct ContractBlock <: Lux.AbstractExplicitContainerLayer{
        (:conv1, :conv2, :bn1, :bn2, :bridge_conv, :sample)
    }
        conv1::Conv
        conv2::Conv
        relu1::Function
        relu2::Function
        bn1::BatchNorm
        bn2::BatchNorm
        bridge_conv::Conv
        sample::Chain
    end

    function ContractBlock(
        kernel_size, de_kernel_size, channel_list;
        downsample = true
    )

		conv1, conv2, relu1, relu2, bn1, bn2, bridge_conv, sample = create_unet_layers(
            kernel_size, de_kernel_size, channel_list;
            downsample = downsample
        )

        ContractBlock(conv1, conv2, relu1, relu2, bn1, bn2, bridge_conv, sample)
    end

    function (m::ContractBlock)(x, ps, st::NamedTuple)
        res, st_bridge_conv = m.bridge_conv(x, ps.bridge_conv, st.bridge_conv)
        x, st_conv1 = m.conv1(x, ps.conv1, st.conv1)
        x, st_bn1 = m.bn1(x, ps.bn1, st.bn1)
        x = relu(x)

        x, st_conv2 = m.conv2(x, ps.conv2, st.conv2)
        x, st_bn2 = m.bn2(x, ps.bn2, st.bn2)
        x = relu(x)

        x = x .+ res

        next_layer, st_sample = m.sample(x, ps.sample, st.sample)

		st = (conv1=st_conv1, conv2=st_conv2, bn1=st_bn1, bn2=st_bn2, bridge_conv=st_bridge_conv, sample=st_sample)
        return next_layer, x, st
    end
end

# ╔═╡ 91e05c6c-e9b3-4a72-84a5-2ce4b1359b1a
md"""
## Expanding Block
"""

# ╔═╡ 70614cac-2e06-48a9-9cf6-9078bc7436bc
begin
    struct ExpandBlock <: Lux.AbstractExplicitContainerLayer{
        (:conv1, :conv2, :bn1, :bn2, :bridge_conv, :sample)
    }
        conv1::Conv
        conv2::Conv
        relu1::Function
        relu2::Function
        bn1::BatchNorm
        bn2::BatchNorm
        bridge_conv::Conv
        sample::Chain
    end

    function ExpandBlock(
        kernel_size, de_kernel_size, channel_list;
        downsample = false)

		conv1, conv2, relu1, relu2, bn1, bn2, bridge_conv, sample = create_unet_layers(
            kernel_size, de_kernel_size, channel_list;
            downsample = downsample
        )

        ExpandBlock(conv1, conv2, relu1, relu2, bn1, bn2, bridge_conv, sample)
    end

    function (m::ExpandBlock)(x, ps, st::NamedTuple)
        x, x1 = x[1], x[2]
        x = cat(x, x1; dims=4)

        res, st_bridge_conv = m.bridge_conv(x, ps.bridge_conv, st.bridge_conv)

        x, st_conv1 = m.conv1(x, ps.conv1, st.conv1)
        x, st_bn1 = m.bn1(x, ps.bn1, st.bn1)
        x = relu(x)

        x, st_conv2 = m.conv2(x, ps.conv2, st.conv2)
        x, st_bn2 = m.bn2(x, ps.bn2, st.bn2)
        x = relu(x)

        x = x .+ res

        next_layer, st_sample = m.sample(x, ps.sample, st.sample)

		st = (conv1=st_conv1, conv2=st_conv2, bn1=st_bn1, bn2=st_bn2, bridge_conv=st_bridge_conv, sample=st_sample)
        return next_layer, st
    end
end

# ╔═╡ 36885de0-aa0e-4037-929f-44e074fb17f5
md"""
## U-Net
"""

# ╔═╡ af56e2f7-2ab8-4ff2-8295-038b3a565cbc
begin
    struct UNet <: Lux.AbstractExplicitContainerLayer{
        (:conv1, :conv2, :conv3, :conv4, :conv5, :de_conv1, :de_conv2, :de_conv3, :de_conv4, :last_conv)
    }
        conv1::Chain
        conv2::Chain
        conv3::ContractBlock
        conv4::ContractBlock
        conv5::ContractBlock
        de_conv1::ContractBlock
        de_conv2::ExpandBlock
        de_conv3::ExpandBlock
        de_conv4::ExpandBlock
        last_conv::Conv
    end

    function UNet(channel)
        conv1 = Chain(
            Conv((5, 5, 5), 1 => channel, stride=1, pad=2),
            BatchNorm(channel),
            relu
        )
        conv2 = Chain(
            Conv((2, 2, 2), channel => 2 * channel, stride=2, pad=0),
            BatchNorm(2 * channel),
            relu
        )
        conv3 = ContractBlock(5, 2, [2 * channel, 2 * channel, 4 * channel])
        conv4 = ContractBlock(5, 2, [4 * channel, 4 * channel, 8 * channel])
        conv5 = ContractBlock(5, 2, [8 * channel, 8 * channel, 16 * channel])

        de_conv1 = ContractBlock(
            5, 2, [16 * channel, 32 * channel, 16 * channel];
            downsample = false
        )
        de_conv2 = ExpandBlock(
            5, 2, [32 * channel, 8 * channel, 8 * channel];
            downsample = false
        )
        de_conv3 = ExpandBlock(
            5, 2, [16 * channel, 4 * channel, 4 * channel];
            downsample = false
        )
        de_conv4 = ExpandBlock(
            5, 2, [8 * channel, 2 * channel, channel];
            downsample = false
        )

        last_conv = Conv((1, 1, 1), 2 * channel => 2, stride=1, pad=0)

		UNet(conv1, conv2, conv3, conv4, conv5, de_conv1, de_conv2, de_conv3, de_conv4, last_conv)
    end

    function (m::UNet)(x, ps, st::NamedTuple)
        # Convolutional layers
        x, st_conv1 = m.conv1(x, ps.conv1, st.conv1)
        x_1 = x  # Store for skip connection
        x, st_conv2 = m.conv2(x, ps.conv2, st.conv2)

        # Downscaling Blocks
        x, x_2, st_conv3 = m.conv3(x, ps.conv3, st.conv3)
        x, x_3, st_conv4 = m.conv4(x, ps.conv4, st.conv4)
        x, x_4, st_conv5 = m.conv5(x, ps.conv5, st.conv5)

        # Upscaling Blocks
        x, _, st_de_conv1 = m.de_conv1(x, ps.de_conv1, st.de_conv1)
        x, st_de_conv2 = m.de_conv2((x, x_4), ps.de_conv2, st.de_conv2)
        x, st_de_conv3 = m.de_conv3((x, x_3), ps.de_conv3, st.de_conv3)
        x, st_de_conv4 = m.de_conv4((x, x_2), ps.de_conv4, st.de_conv4)

        # Concatenate with first skip connection and apply last convolution
        x = cat(x, x_1; dims=4)
        x, st_last_conv = m.last_conv(x, ps.last_conv, st.last_conv)

        # Merge states
        st = (
		conv1=st_conv1, conv2=st_conv2, conv3=st_conv3, conv4=st_conv4, conv5=st_conv5, de_conv1=st_de_conv1, de_conv2=st_de_conv2, de_conv3=st_de_conv3, de_conv4=st_de_conv4, last_conv=st_last_conv
        )

        return x, st
    end
end

# ╔═╡ df2dd9a7-045c-44a5-a62c-8d9f2541dc14
md"""
# Training Set Up
"""

# ╔═╡ 69880e6d-162a-4aae-94eb-103bd35ac3c9
import Zygote

# ╔═╡ 12d42392-ad7b-4c5f-baf5-1f2c6052669e
import Optimisers

# ╔═╡ 70bc36db-9ee3-4e1d-992d-abbf55c52070
# using Losers: hausdorff_loss, dice_loss

# ╔═╡ 8598dfca-8929-4ec3-9eb5-09c240c3fdba
# function compute_loss(x, y, model, ps, st, epoch)
#     alpha = max(1.0 - 0.01 * epoch, 0.01)
#     beta = 1.0 - alpha

#     y_pred, st = model(x, ps, st)

#     y_pred_softmax = softmax(y_pred, dims=4)
#     y_pred_binary = round.(y_pred_softmax[:, :, :, 2, :])
#     y_binary = y[:, :, :, 2, :]

#     # Compute loss
#     loss = 0.0
#     for b in axes(y, 5)
#         _y_pred = y_pred_binary[:, :, :, b]
#         _y = y_binary[:, :, :, b]

# 		local _y_dtm, _y_pred_dtm
# 		ignore_derivatives() do
# 			_y_dtm = transform(boolean_indicator(_y))
# 			_y_pred_dtm = transform(boolean_indicator(_y_pred))
# 		end
		
# 		hd = hausdorff_loss(_y_pred, _y, _y_pred_dtm, _y_dtm)
# 		dsc = dice_loss(_y_pred, _y)
# 		loss += alpha * dsc + beta * hd
#     end
	
#     return loss / size(y, 5), y_pred_binary, st
# end

# ╔═╡ 7cde37c8-4c59-4583-8995-2b01eda95cb3
md"""
## Optimiser
"""

# ╔═╡ 10007ee0-5339-4544-bbcd-ac4eed043f50
function create_optimiser(ps)
    opt = Optimisers.ADAM(0.01f0)
    return Optimisers.setup(opt, ps)
end

# ╔═╡ a25bdfe6-b24d-446b-926f-6e0727d647a2
md"""
## Loss function
"""

# ╔═╡ c0881c99-6cc8-4518-810a-17f631b3eb7b
function dice_loss(ŷ, y, ϵ=1e-5)
    return loss = 1 - ((2 * sum(ŷ .* y) + ϵ) / (sum(ŷ .* ŷ) + sum(y .* y) + ϵ))
end

# ╔═╡ 496712da-3cf0-4fbc-b869-72372e73612b
function compute_loss(x, y, model, ps, st)

    y_pred, st = model(x, ps, st)

    y_pred_softmax = softmax(y_pred, dims=4)
    y_pred_binary = round.(y_pred_softmax[:, :, :, 2, :])
    y_binary = y[:, :, :, 2, :]

    # Compute loss
    loss = 0.0
    for b in axes(y, 5)
        _y_pred = y_pred_binary[:, :, :, b]
        _y = y_binary[:, :, :, b]
		
		dsc = dice_loss(_y_pred, _y)
		loss += dsc
    end
	
    return loss / size(y, 5), y_pred_binary, st
end

# ╔═╡ 45949f7f-4e4a-4857-af43-ff013dbdd137
md"""
# Train
"""

# ╔═╡ 402ba194-350e-4ff3-832b-6651be1d9ce7
dev = gpu_device()

# ╔═╡ bbdaf5c5-9faa-4b61-afab-c0242b8ca034
model = UNet(4)

# ╔═╡ 6ec3e34b-1c57-4cfb-a50d-ee786c2e4559
begin
	ps, st = Lux.setup(rng, model)
	ps, st = ps |> dev, st |> dev
end

# ╔═╡ bacc8b9f-8b8d-4230-bcff-eb330ae328b1
function train_model(model, ps, st, train_loader, num_epochs, dev)
    opt_state = create_optimiser(ps)

    for epoch in 1:num_epochs
		@info "Epoch: $epoch"

		# Training Phase
        for (x, y) in train_loader
			x, y = x |> dev, y |> dev
			
            # Forward pass
            y_pred, st = Lux.apply(model, x, ps, st)
            loss, y_pred, st = compute_loss(x, y, model, ps, st)
			# @info "Training Loss: $loss"

            # Backward pass
			(loss_grad, st_), back = Zygote.pullback(p -> Lux.apply(model, x, p, st), ps)
            gs = back((one.(loss_grad), nothing))[1]

            # Update parameters
            opt_state, ps = Optimisers.update(opt_state, ps, gs)
        end

		# Validation Phase
		total_loss = 0.0
		num_batches = 0
	    for (x, y) in val_loader
			x, y = x |> dev, y |> dev
			
	        # Forward Pass
	        y_pred, st = Lux.apply(model, x, ps, st)
	        loss, _, _ = compute_loss(x, y, model, ps, st)
	
	        total_loss += loss
	        num_batches += 1
	    end
		avg_loss = total_loss / num_batches
		@info "Validation Loss: $avg_loss"
    end

    return ps, st
end

# ╔═╡ a2e88851-227a-4719-8828-6064f9d3ef81
if LuxCUDA.functional()
	num_epochs = 20
else
	num_epochs = 2
end

# ╔═╡ 5cae73af-471c-4068-b9ff-5bc03dd0472d
train_model(model, ps, st, train_loader, num_epochs, dev)

# ╔═╡ Cell order:
# ╠═d4f7e164-f9a6-47ee-85a7-dd4e0dec10ee
# ╠═8d4a6d5a-c437-43bb-a3db-ab961b218c2e
# ╠═c8d6553a-90df-4aeb-aa6d-a213e16fab48
# ╟─af798f6b-7549-4253-b02b-2ed20dc1125b
# ╠═83b95cee-90ed-4522-b9a8-79c082fce02e
# ╠═af50e5f3-1a1c-47e5-a461-ffbee0329309
# ╟─f0e64ba5-5e11-4ddb-91d3-2a34c60dc6bf
# ╠═7353b7ce-8b33-4602-aed7-2aa24864aca5
# ╠═de5efc37-db19-440e-9487-9a7bea84996d
# ╠═3ab44a2a-692f-4603-a5a8-81f1d260c13e
# ╠═562b3772-89cc-4390-87c3-e7260c8aa86b
# ╠═db2ccf3a-437a-4dfa-ad05-2526c0e2bde0
# ╠═8e2f2c6d-127d-42a6-9906-970c09a22e61
# ╟─ec7734c3-33a5-43c7-82db-2db4dbdc9587
# ╠═cdfd2412-897d-4642-bb69-f8031c418446
# ╠═b1516500-ad83-41d2-8a1d-093cd0d948e3
# ╠═3e896957-61d8-4750-89bd-be02383417ec
# ╠═99211382-7de9-4e97-872f-d0c01b8f8307
# ╠═6d34b756-4da8-427c-91f5-dfb022c4e715
# ╠═9577b91b-faa4-4fc5-9ec2-ed8ca94f2afe
# ╟─ae3d24e4-2216-4744-9093-0d2a8bbaae2d
# ╠═18b31959-9cdf-41d9-a389-7c18febf7b07
# ╠═72827ad5-4820-4545-8099-1033d962970e
# ╠═8ad7b2bb-1672-473a-a7b5-bf505733f7a3
# ╠═317c1571-d232-4cab-ac10-9fc3b7ad33b0
# ╠═ac2ed012-2b64-42b2-b97c-2a5352af9ec8
# ╠═c5539898-6b0c-4172-ba6c-9bfe2819c9fb
# ╟─03bab55a-6e5e-4b9f-b56a-7e9f993576eb
# ╠═d40f19dc-f06e-44ef-b82b-9763ff1f1189
# ╠═4d75f114-225f-45e2-a683-e82ff137d909
# ╠═2032b7e6-ceb7-4c08-9b0d-bc704f5e4104
# ╟─2ec43028-c1ab-4df7-9cfe-cc1a4919a7cf
# ╟─a6316144-c809-4d2a-bda1-d5128dcf89d3
# ╠═f8fc2cee-c1bd-477d-9595-9427e8764bd6
# ╟─7cb986f8-b338-4046-b569-493e443a8dcb
# ╟─d7e75a72-8281-432c-abab-c254f8c94d3c
# ╟─9dc89870-3d99-472e-8974-712e34a3a789
# ╠═0f5d7796-2c3d-4b74-86c1-a1d4e3922011
# ╟─6e2bfcfb-77e3-4532-a14d-10f4b91f2f54
# ╟─bae79c05-034a-4c39-801a-01229b618e94
# ╟─1494df6e-f407-42c4-8404-1f4871a2f817
# ╠═a3f44d7c-efa3-41d0-9509-b099ab7f09d4
# ╟─b3fc9578-6b40-4afc-bb58-c772a61a60a5
# ╠═3e938872-a390-40ba-8b00-b132f988e2d3
# ╟─1d65b1d1-82de-40ca-aaba-9eee23883cf3
# ╠═40762509-b26e-47f5-8b49-e7100fdeb72a
# ╟─91e05c6c-e9b3-4a72-84a5-2ce4b1359b1a
# ╠═70614cac-2e06-48a9-9cf6-9078bc7436bc
# ╟─36885de0-aa0e-4037-929f-44e074fb17f5
# ╠═af56e2f7-2ab8-4ff2-8295-038b3a565cbc
# ╟─df2dd9a7-045c-44a5-a62c-8d9f2541dc14
# ╠═a6669580-de24-4111-a7cb-26d3e727a12e
# ╠═dfc9377a-7cc1-43ba-bb43-683d24e67d79
# ╠═c283f9a3-6a76-4186-859f-21cd9efc131f
# ╠═69880e6d-162a-4aae-94eb-103bd35ac3c9
# ╠═12d42392-ad7b-4c5f-baf5-1f2c6052669e
# ╟─70bc36db-9ee3-4e1d-992d-abbf55c52070
# ╟─8598dfca-8929-4ec3-9eb5-09c240c3fdba
# ╟─7cde37c8-4c59-4583-8995-2b01eda95cb3
# ╠═10007ee0-5339-4544-bbcd-ac4eed043f50
# ╟─a25bdfe6-b24d-446b-926f-6e0727d647a2
# ╠═c0881c99-6cc8-4518-810a-17f631b3eb7b
# ╠═496712da-3cf0-4fbc-b869-72372e73612b
# ╟─45949f7f-4e4a-4857-af43-ff013dbdd137
# ╠═402ba194-350e-4ff3-832b-6651be1d9ce7
# ╠═bbdaf5c5-9faa-4b61-afab-c0242b8ca034
# ╠═6ec3e34b-1c57-4cfb-a50d-ee786c2e4559
# ╠═bacc8b9f-8b8d-4230-bcff-eb330ae328b1
# ╠═a2e88851-227a-4719-8828-6064f9d3ef81
# ╠═5cae73af-471c-4068-b9ff-5bc03dd0472d
